"""fashionclip_vision.onnx(+.onnx.data)를 이 디렉터리에 재생성한다.

FashionCLIP(patrickjohncyh/fashion-clip) 이미지 인코더만 감싸는 래퍼
(get_image_features(...).pooler_output -> L2 정규화)를 ONNX로 내보낸다.
텍스트 인코더는 이 스파이크의 용도(이미지->벡터)에 안 쓰이므로 애초에
그래프에 안 들어간다(dynamo 트레이싱이 실제 실행된 서브그래프만 캡처).

산출물은 git에 커밋하지 않는다(.gitignore, 352.8MB, 규코드 재생성 가능
— docs/task_realtime_embedding_v1.md §10(a)/§16 참고).

사용법:
    pip install torch torchvision transformers onnx onnxscript
    python export_onnx.py
"""
import os

import torch
import torch.nn.functional as F
from transformers import CLIPModel

OUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fashionclip_vision.onnx")

model = CLIPModel.from_pretrained("patrickjohncyh/fashion-clip").eval()


class VisionEncoder(torch.nn.Module):
    def __init__(self, clip_model):
        super().__init__()
        self.clip_model = clip_model

    def forward(self, pixel_values):
        out = self.clip_model.get_image_features(pixel_values=pixel_values)
        return F.normalize(out.pooler_output, dim=-1)


wrapper = VisionEncoder(model).eval()
dummy = torch.randn(1, 3, 224, 224)
with torch.no_grad():
    torch.onnx.export(
        wrapper,
        (dummy,),
        OUT_PATH,
        input_names=["pixel_values"],
        output_names=["image_embeds"],
        dynamic_axes={"pixel_values": {0: "batch"}, "image_embeds": {0: "batch"}},
        opset_version=17,
    )

print(f"저장 완료: {OUT_PATH}")
data_path = OUT_PATH + ".data"
print(f"그래프: {os.path.getsize(OUT_PATH) / 1e6:.2f} MB")
if os.path.exists(data_path):
    print(f"외부 가중치: {os.path.getsize(data_path) / 1e6:.1f} MB")
