# fpga-digital-filter
FPGA implementation of digital filters (FIR/IIR) in VHDL
## System Architecture & Hardware Setup

1. **Analog-to-Digital Conversion (ADC):**
   * An Arduino board acts as the external ADC, sampling the analog noise-contaminated signal from the motor sensor/function generator via its internal 8-bit ADC.
   * The digital samples are sent as an 8-bit parallel bus directly to the FPGA's expansion header (GPIO).

2. **Digital Signal Processing (FPGA):**
   * An Altera DE1 (Cyclone II EP2C20F484C7) board runs the VHDL filter pipeline (`filter.vhd` / `filtropb.vhd`), performing real-time MAC (Multiply-Accumulate) operations to eliminate high-frequency noise.

3. **Digital-to-Analog Conversion (DAC):**
   * The filtered 8-bit digital output from the FPGA drives an external R-2R resistor ladder DAC.
   * The reconstructed analog signal is displayed on an oscilloscope to verify noise reduction and frequency response.
