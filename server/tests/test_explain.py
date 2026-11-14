import numpy as np
import pytest
import torch
from torch import nn
from PIL import Image
from model_integration.explain import gradcam,restore_cam


def test_gradcam_depends_on_target_and_removes_hook():
    class Net(nn.Module):
        def __init__(self):
            super().__init__();self.feature=nn.Conv2d(1,2,1,bias=False)
            with torch.no_grad():self.feature.weight[:,0,0,0]=torch.tensor([1.,-1.])
        def forward(self,x):return self.feature(x).mean((2,3))
    model=Net().eval().requires_grad_(False)
    x=torch.tensor([[[[1.,1.,-1.,-1.],[1.,1.,-1.,-1.]]]])
    first=gradcam(model,model.feature,x,0);second=gradcam(model,model.feature,x,1)
    assert first[:,:2].sum()>0 and first[:,2:].sum()==0
    assert second[:,:2].sum()==0 and second[:,2:].sum()>0
    assert not model.feature._forward_hooks
    assert all(p.grad is None for p in model.parameters())


def test_padding_inverse_and_empty_explanation():
    cam=np.zeros((10,10),dtype=np.float32);cam[0:2,:]=100
    restored,status=restore_cam(cam,(100,40),padded=True)
    assert restored.size==(100,40) and status=='no_positive_signal'
    restored,status=restore_cam(np.ones((10,10),np.float32),(40,100),padded=True)
    assert restored.size==(40,100) and np.asarray(restored).min()==255 and status=='available'
