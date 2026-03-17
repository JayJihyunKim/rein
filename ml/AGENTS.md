# ml/AGENTS.md — ML 파이프라인 규칙

> 이 파일은 ml/ 디렉토리 작업 시 자동으로 로드된다.
> 전역 AGENTS.md를 상속하며, 여기서는 ML 파이프라인 특화 규칙만 추가한다.

---

## 기술 스택

- **Language**: Python 3.12+
- **ML Framework**: PyTorch / scikit-learn
- **실험 추적**: MLflow 또는 Weights & Biases
- **데이터 버저닝**: DVC
- **Testing**: pytest

---

## 실행 명령어

```bash
python train.py --config configs/default.yaml   # 학습
python evaluate.py --model [checkpoint]          # 평가
dvc repro                                        # 파이프라인 재실행
mlflow ui                                        # 실험 결과 확인
pytest tests/                                    # 테스트
```

---

## 디렉토리 구조

```
ml/
├── configs/          # 실험 설정 파일 (YAML)
├── data/             # 데이터 (DVC로 버전 관리)
│   ├── raw/
│   └── processed/
├── models/           # 모델 정의
├── pipelines/        # 학습/평가 파이프라인
├── notebooks/        # 탐색적 분석 (실험용만, 운영 코드 금지)
├── tests/
└── mlruns/           # MLflow 실험 로그
```

---

## ML 코딩 규칙

- 모든 실험은 설정 파일(YAML)로 관리 — 하드코딩된 하이퍼파라미터 금지
- 학습 결과는 MLflow/W&B에 반드시 로깅
- 재현 가능성: 랜덤 시드 고정 및 설정 파일에 기록
- 데이터 버전은 DVC로 관리 (raw 데이터 Git 커밋 금지)
- 모델 체크포인트는 Git 커밋 금지 (DVC 또는 MLflow artifact 사용)

---

## 실험 기록 규칙

모든 실험은 아래를 포함해야 한다:
- 실험 목적 및 가설
- 데이터셋 버전 (DVC hash)
- 하이퍼파라미터 전체 목록
- 평가 지표 (train/val/test)
- 결론 및 다음 실험 계획

---

## 금지 패턴

- Jupyter Notebook에 운영 코드 작성 금지 (탐색용만)
- 학습 데이터 Git 직접 커밋 금지
- 실험 결과를 파일명으로만 관리 금지 (`model_v3_final_final.pt` 등)
- 랜덤 시드 미설정 학습 금지
