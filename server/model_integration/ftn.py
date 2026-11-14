"""Architetture di inferenza congelate dalla ricognizione del 10 novembre 2026.

Mantiene nomi, forme dei parametri e forward della versione esaminata.
Il pooling PSP non e applicato; i hook per spiegazioni LRP non servono
all'inferenza e non vengono registrati. Provenienza e hash nel manifest.
"""
import torch
from torch import nn


class Mlp(nn.Module):
    def __init__(self, dimension):
        super().__init__()
        self.fc1 = nn.Linear(dimension, dimension)
        self.act = nn.GELU()
        self.fc2 = nn.Linear(dimension, dimension)
        self.drop = nn.Dropout(0.0)

    def forward(self, x):
        return self.drop(self.fc2(self.drop(self.act(self.fc1(x)))))


class Attention(nn.Module):
    def __init__(self, dimension, heads):
        super().__init__()
        self.num_heads = heads
        self.in_dim = dimension
        self.scale = (dimension // heads) ** -0.5
        self.qkv = nn.Linear(dimension, dimension * 3, bias=False)
        self.attn_drop = nn.Dropout(0.0)
        self.proj = nn.Linear(dimension, dimension)
        self.proj_drop = nn.Dropout(0.0)

    def forward(self, x):
        batch, tokens, _ = x.shape
        qkv = self.qkv(x).reshape(batch, tokens, 3, self.num_heads,
                                  self.in_dim // self.num_heads).permute(2, 0, 3, 1, 4)
        query, key, value = qkv[0], qkv[1], qkv[2]
        attention = (query @ key.transpose(-2, -1) * self.scale).softmax(dim=-1)
        result = (attention @ value).transpose(1, 2).reshape(batch, tokens, self.in_dim)
        return self.proj_drop(self.proj(result))


class SpatialTransformer(nn.Module):
    def __init__(self, dimension, heads):
        super().__init__()
        self.norm1 = nn.LayerNorm(dimension)
        self.attn = Attention(dimension, heads)
        self.drop_path = nn.Identity()
        self.norm2 = nn.LayerNorm(dimension)
        self.mlp1 = Mlp(dimension)

    def forward(self, x):
        x = x + self.drop_path(self.attn(self.norm1(x)))
        return x + self.drop_path(self.mlp1(self.norm2(x)))


class ClassificationEncoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 48, 3, stride=2, padding=1), nn.BatchNorm2d(48), nn.ReLU(inplace=True),
            nn.Conv2d(48, 96, 3, stride=2, padding=1), nn.BatchNorm2d(96), nn.ReLU(inplace=True),
            nn.Conv2d(96, 192, 3, stride=2, padding=1), nn.BatchNorm2d(192), nn.ReLU(inplace=True),
            nn.Conv2d(192, 256, 3, stride=2, padding=1), nn.BatchNorm2d(256), nn.ReLU(inplace=True),
            nn.Conv2d(256, 256, 1),
        )
        self.cls_token = nn.Parameter(torch.zeros(1, 1, 256))
        self.pos_embed = nn.Parameter(torch.zeros(1, 197, 256))

    def forward(self, x):
        x = self.stem(x).flatten(2).transpose(1, 2)
        return torch.cat((self.cls_token.expand(x.size(0), -1, -1), x), dim=1) + self.pos_embed


class FTNClassification(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = ClassificationEncoder()
        self.blocks = nn.ModuleList([SpatialTransformer(256, 8) for _ in range(12)])
        self.pre_hade_norm = nn.InstanceNorm2d(256)
        self.classifier = nn.Linear(256, 7)

    def forward(self, x):
        x = self.encoder(x)
        for block in self.blocks:
            x = block(x)
        return self.classifier(x[:, 0, :])


def feature_map(tokens):
    batch, count, channels = tokens.shape
    side = int(count ** 0.5)
    if side * side != count:
        raise ValueError('La griglia dei token deve essere quadrata.')
    return tokens.transpose(1, 2).reshape(batch, channels, side, side)


class SegmentationEncoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.swt_0 = nn.Conv2d(3, 64, 7, stride=4, padding=2)
        self.swt_1 = nn.Conv2d(64, 128, 3, stride=2, padding=1)
        self.swt_2 = nn.Conv2d(128, 256, 3, stride=2, padding=1)
        self.attention1 = SpatialTransformer(64, 2)
        self.attention2 = SpatialTransformer(128, 4)

    def forward(self, x):
        first = feature_map(self.attention1(self.swt_0(x).flatten(2).transpose(1, 2)))
        second = feature_map(self.attention2(self.swt_1(first).flatten(2).transpose(1, 2)))
        return self.swt_2(second).flatten(2).transpose(1, 2), [first, second]


class SegmentationDecoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.proj = nn.Sequential(nn.Linear(256, 128))
        self.attention1 = SpatialTransformer(256, 1)
        self.attention2 = SpatialTransformer(128, 1)
        self.swt_0 = nn.Sequential(nn.Conv2d(256, 64, 3, padding=1))
        # UpsamplingBilinear2d mantiene align_corners=True come nel sorgente.
        self.upsample = nn.UpsamplingBilinear2d(scale_factor=2)

    def forward(self, x, encoder):
        x = feature_map(self.proj(x))
        x = torch.cat([encoder[-1], self.upsample(x)], dim=1).flatten(2).transpose(1, 2)
        x = self.swt_0(feature_map(self.attention1(x)))
        x = torch.cat([encoder[-2], self.upsample(x)], dim=1).flatten(2).transpose(1, 2)
        return feature_map(self.attention2(x))


class FTNSegmentation(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = SegmentationEncoder()
        self.blocks = nn.ModuleList([SpatialTransformer(256, 8) for _ in range(12)])
        self.decoder = SegmentationDecoder()
        self.pre_hade_norm = nn.InstanceNorm2d(128)
        self.classifier = nn.Conv2d(128, 2, 3, padding=1)
        self.upsample = nn.Upsample(scale_factor=4, mode='bilinear', align_corners=False)

    def forward(self, x):
        x, encoder = self.encoder(x)
        for block in self.blocks:
            x = block(x)
        return self.upsample(self.classifier(self.pre_hade_norm(self.decoder(x, encoder))))
