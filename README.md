# FPGA_SSB

一个面向自我探索的 FPGA + RF 小项目：
使用 **Cyclone IV E EP4CE10（4CE10）** + **AD9744（14-bit 并行 DAC）** + **I2S 数字麦克风**，实现简化的语音 SSB（单边带）发射数字链路。

## 项目定位

- 这是学习/实验工程，不是产品化项目。
- 目标是把“音频采集 → I/Q 生成 → SSB 调制 → DAC 输出”在 FPGA 上跑通。
- 重点在“可综合、可布线、可时序收敛”的真实实现。

## 硬件与工具

- FPGA：**EP4CE10F17C8**
- DAC：**AD9744**
- 音频输入：**I2S 麦克风模块**
- 开发环境：**Quartus II 13.1**

## 信号链（简版）

```text
I2S麦克风
  -> I2S接收/去直流
  -> 音频预处理
  -> Hilbert滤波（生成I/Q）
  -> CIC插值
  -> NCO正交调制
  -> USB/LSB生成
  -> AD9744并行DAC输出
```

## 你可以学到什么

- FPGA 内的 I2S 采样与时序对齐
- Hilbert / I-Q 在 SSB 里的作用
- NCO（相位累加器 + ROM）基础
- 插值与定点信号链处理思路
- Quartus 工程约束与时序分析流程

## 代码入口

- `HF_SDR.v`：顶层与主要处理链
- `sine_rom.v`：NCO 正弦 ROM
- `sys_pll.v`：PLL 相关
- `dac_ddio.vhd`：DAC DDIO 输出
- `HF_SDR.qsf`：工程与引脚约束
- `HF_SDR.sdc`：时钟与时序约束

建议阅读顺序：
`HF_SDR.v` 顶层端口 → `i2s_rx` → `tx_audio_proc` → `hilbert_filter` → `cic_interpolator` → `multi_band_modulator`。

## 使用提醒

- 本项目涉及 RF 发射实验，请遵守当地无线电法规。
- 接后级功放/天线前，请先确认滤波、频谱纯净度与功率安全。

## 后续计划（可选）

- 补充 testbench
- 整理滤波器系数说明
- 增加频谱与板级连接图
