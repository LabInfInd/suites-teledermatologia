"""Grad-CAM for a declared target score. No thresholded heatmap is a lesion mask."""
import math
import numpy as np
import torch
from PIL import Image


def spatial(tensor):
    if tensor.ndim == 4:
        return tensor
    if tensor.ndim != 3:
        raise ValueError('Unsupported target activation shape')
    # ViT: remove CLS and any prefix tokens; DINOv2 serving recipe has one CLS.
    patches=tensor[:,1:,:];side=math.isqrt(patches.shape[1])
    if side*side != patches.shape[1]:
        raise ValueError('Non-square token activation grid')
    return patches.transpose(1,2).reshape(tensor.shape[0],tensor.shape[2],side,side)


def gradcam(model, layer, tensor, target, *, probability=False):
    activations=[]
    handle=layer.register_forward_hook(lambda _m,_i,out: activations.append(out))
    try:
        with torch.enable_grad():
            x=tensor.detach().clone().requires_grad_(True)
            logits=model(x)
            if not torch.isfinite(logits).all():raise ValueError('Non-finite classification logits')
            score=logits.softmax(1)[0,target] if probability else logits[0,target]
            activation=activations[-1]
            gradient,=torch.autograd.grad(score,activation)
            a,g=spatial(activation),spatial(gradient)
            cam=(a*g.mean(dim=(2,3),keepdim=True)).sum(1).relu()[0]
            if not torch.isfinite(cam).all():raise ValueError('Non-finite explanation')
            return cam.detach().cpu().numpy()
    finally:
        handle.remove()


def restore_cam(cam, image_size, *, padded):
    # Upsample first, then invert square padding using exactly the input offsets.
    w,h=image_size;side=max(w,h)
    heat=Image.fromarray(np.asarray(cam,dtype=np.float32))
    if padded:
        heat=heat.resize((side,side),Image.Resampling.BILINEAR)
        left,top=(side-w)//2,(side-h)//2
        heat=heat.crop((left,top,left+w,top+h))
    else:
        heat=heat.resize((w,h),Image.Resampling.BILINEAR)
    values=np.maximum(np.asarray(heat,dtype=np.float32),0)
    peak=float(values.max());signal=peak>1e-12
    values=values/peak if signal else np.zeros_like(values)
    return Image.fromarray(np.rint(values*255).astype(np.uint8)),('available' if signal else 'no_positive_signal')
