# QE 7.6 HSE＋PAW 技術資料 / Technical notes

記録日 / Recorded: 2026-11-12 JST

## 日本語

| 話題 | 資料 |
| --- | --- |
| GPUの高速化：交換補正をGPU上の一括行列演算へ移す | [GPU高速化](GPU_ACCELERATION.ja.md) |
| CPUの不具合修正：pool数でPAW交換項が欠落する原因と数値照合 | [CPUのPAW補正欠落](CPU_PAW_POOL_BUG.ja.md) |
| CPUの高速化：一括演算への変更、速度試験、k点あたりの時間 | [CPU高速化](CPU_ACCELERATION.ja.md) |

各資料に前提、変更内容、測定結果、検証範囲を記載しています。

## English

| Topic | Document |
| --- | --- |
| GPU acceleration: move exchange augmentation to batched GPU linear algebra | [GPU acceleration](GPU_ACCELERATION.en.md) |
| CPU correctness repair: missing PAW exchange terms in additional pools | [CPU PAW pool omission](CPU_PAW_POOL_BUG.en.md) |
| CPU acceleration: batching, timing tests, and time per k point | [CPU acceleration](CPU_ACCELERATION.en.md) |

Each document states its assumptions, implementation changes, measurements, and validation scope.
