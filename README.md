# ⚡ Real-Time FIR Digital Filter on FPGA DE1 (Altera Cyclone II)

![VHDL](https://img.shields.io/badge/VHDL-1993-00599C?style=for-the-badge&logo=vhdl&logoColor=white)
![FPGA](https://img.shields.io/badge/FPGA-Altera_DE1_(EP2C20F484C7)-0071C5?style=for-the-badge)
![Quartus](https://img.shields.io/badge/Quartus_II-v13.0-003366?style=for-the-badge)
![MATLAB](https://img.shields.io/badge/MATLAB-R2021a-ED8B00?style=for-the-badge&logo=mathworks&logoColor=white)
![UPTC](https://img.shields.io/badge/UPTC-Ingeniería_Electrónica-FFCC00?style=for-the-badge)

> **Proyecto Parcial II — Electrónica Digital II**  
> **Universidad Pedagógica y Tecnológica de Colombia (UPTC)**  
> **Escuela de Ingeniería Electrónica — Tunja, Colombia**  
> **Docente:** Ing. Ilber Adonayt Ruge Ruge  
> **Autores:** [Néstor Alejandro Menjuren Sepúlveda](https://github.com/AlejandroNass) & David Fernando Gamarra Gaona  

---

## 📹 Video de Sustentación

[![Sustentación del Proyecto - Filtro FIR en FPGA] (https://youtu.be/wvjWcC5dogA "Ver sustentación en YouTube")

> 💡 **Haz clic en la imagen** para reproducir la sustentación completa del proyecto en YouTube.

---

## 📖 Descripción del Proyecto

Este repositorio contiene el diseño, síntesis en VHDL y validación experimental en hardware real de un **sistema de filtrado digital en tiempo real** implementado en la tarjeta **FPGA Altera DE1 (Cyclone II EP2C20F484C7)**.

El objetivo principal es capturar la señal analógica con ruido procedente de un **conjunto motor-sensor DC** (ruido electromagnético originado por la conmutación de escobillas, armónicos y tensión de rizo), procesarla mediante un **filtro paso bajo de respuesta finita al impulso (FIR)** sintetizado en VHDL utilizando una arquitectura de suma de productos (MAC), y reconstruir la señal analógica filtrada para su análisis y comprobación en tiempo real mediante osciloscopio.

---

## 🛠️ Arquitectura del Sistema

El flujo de procesamiento de señales se divide en 5 etapas interconectadas de manera modular:

```
┌───────────────┐     ┌───────────────┐     ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│  Motor-Sensor │ ──> │   ADC 8-bits  │ ──> │   FPGA DE1    │ ──> │   DAC R-2R    │ ──> │ Osciloscopio  │
│  DC (Entrada) │     │   (Arduino)   │     │ (Filtro FIR)  │     │   (8-bits)    │     │ (Verificación)│
└───────────────┘     └───────────────┘     └───────────────┘     └───────────────┘     └───────────────┘
                                                    ▲
                                            ┌───────┴───────┐
                                            │ Interfaz PS/2 │
                                            │  & Control    │
                                            │      PWM      │
                                            └───────────────┘
```

1. **Captura Analógica & ADC (8 bits):** Muestreo discreto en tiempo real de la tensión ruidosa generada por el segundo motor DC operando como sensor/generador acoplado mecánicamente al motor principal.
2. **Interfaz de Entrada a FPGA:** Transmisión del bus paralelo de 8 bits hacia los pines de expansión GPIO de la tarjeta Altera DE1.
3. **Procesamiento Digital de Señal (DSP):** Ejecución síncrona del algoritmo del filtro FIR ($y[n] = \sum h[k] \cdot x[n-k]$) mediante una línea de retardos y acumuladores cuantizados en punto fijo dentro de la FPGA.
4. **Reconstrucción Analógica (DAC R-2R):** Conversión de la palabra digital de salida de 8 bits a tensión analógica mediante un arreglo de resistencias tipo R-2R.
5. **Control de Consigna & Visualización:** Decodificación de teclado PS/2 para ajuste de referencia, generación de señal PWM hacia el driver L298N del motor actuador y despliegue de velocidad en displays de 7 segmentos.

---

## 🎛️ Especificaciones del Filtro FIR (MATLAB)

El filtro fue diseñado empleando la herramienta **Filter Designer (FDA Tool)** de MATLAB con los siguientes parámetros optimizados para la plataforma:

* **Tipo de Filtro:** FIR Paso Bajo (Low-Pass Filter, no recursivo)
* **Respuesta en Fase:** Fase Lineal (Evita la distorsión de forma de onda en el tiempo)
* **Arquitectura Hardware:** Registros de desplazamiento + Unidad MAC
* **Frecuencia de Muestreo ($f_s$):** $200\text{ Hz}$
* **Frecuencia de Paso ($f_{pass}$):** $20\text{ Hz}$
* **Frecuencia de Corte ($f_{stop}$):** $40\text{ Hz}$
* **Cuantización:** Punto fijo (*Fixed-Point*) con bus de entrada de 8 bits y bus de salida de 8 bits

---

## 📂 Estructura del Repositorio

```text
fpga-digital-filter/
├── .gitignore
├── README.md                  # Documentación principal del proyecto
├── filter.vhd                 # Módulo VHDL del filtro FIR (coeficientes y estructura MAC)
├── filtropb.vhd               # Filtro paso bajo auxiliar/complementario
├── proyecto_filtro_top.vhd    # Entidad Top-Level con interconexión de submódulos
├── pwm_ps2_top.vhd            # Módulo de lectura PS/2 y generación de PWM para el motor
└── tb_proyecto_filtro_top.vhd # Testbench para simulación funcional en ModelSim/Quartus
```

---

## 🔬 Resultados y Validación Experimental

La efectividad del filtrado digital se verificó mediante mediciones en tiempo real en un osciloscopio **GW INSTEK**, comparando la señal ruidosa del sensor (**Canal 1 - Azul / Entrada ADC**) contra la señal limpia procesada (**Canal 2 - Amarillo / Salida DAC**) a diferentes frecuencias de rotación del motor:

| Velocidad del Motor | Señal de Entrada (ADC) | Señal Filtrada (DAC) | Observación Técnica |
| :---: | :---: | :---: | :--- |
| **60 RPS** | Rizo de baja amplitud + picos de conmutación | Onda visualmente estabilizada | Eliminación de transitorios iniciales |
| **100 RPS** | Incremento en alta frecuencia de ruido | Tensión continua suavizada | Atenuación efectiva del rizo principal |
| **150 RPS** | Ruido electromagnético severo | Señal media filtrada | Preservación de la componente DC útil |
| **200 RPS** | Frecuencia fundamental con armónicos | Tensión continua limpia | Máximo desempeño de la atenuación FIR |

---

## 🚀 Instrucciones para Replicación y Síntesis

1. **Clonar el repositorio:**
   ```bash
   git clone https://github.com/AlejandroNass/fpga-digital-filter.git
   ```
2. **Abrir en Altera Quartus II:**
   * Crear un nuevo proyecto seleccionando el dispositivo objetivo **Cyclone II EP2C20F484C7**.
   * Agregar todos los archivos VHDL (`.vhd`) del repositorio.
3. **Asignación de Pines (Pin Planner):**
   * Asignar el reloj principal del sistema de $50\text{ MHz}$ (`clock`).
   * Asignar los buses paralelos `filtering[7..0]` (Entrada ADC) y `filter_out[7..0]` (Salida DAC) a los cabezales GPIO correspondientes.
4. **Compilar y Cargar:**
   * Ejecutar la síntesis completa y el análisis de tiempos.
   * Cargar el archivo `.sof` compilado a la tarjeta FPGA DE1 mediante **Altera Programmer** (USB-Blaster).

---

## 📄 Licencia y Créditos

Desarrollado para la asignatura **Electrónica Digital II** de la **Universidad Pedagógica y Tecnológica de Colombia (UPTC)**.  
Enlace oficial de la sustentación en YouTube: [https://youtu.be/wvjWcC5dogA](https://youtu.be/wvjWcC5dogA).
