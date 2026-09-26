# DataCenterThermalSim.jl

**A transient rack thermal and cooling-control model driven by compute telemetry.** The package couples a silicon die and cold-plate coolant pass to a feedback PID flow controller and a cubic hydraulic pump-power estimate. Inputs use SI units: seconds, watts, kilograms per second, joules, and degrees Celsius for temperature differences/state values.

## Problem overview

High-density compute loads change faster than fixed cooling schedules can usefully respond. This compact model provides a transparent engineering baseline for studying die temperature, coolant temperature, flow demand, and pump energy during realistic workload ramps and spikes. `TelemetryProfile` accepts validated time/power data; `load_telemetry_csv` reads CSV columns named `time_s` and `p_it_W`. When no file is supplied, the demo generates a deterministic workload profile that moves between 5 kW and 30 kW.

## System schematic

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/system_schematic.dark.svg">
  <img alt="Liquid-cooled rack thermal path from IT load through the die and cold plate, with coolant pump flow controlled by a PID loop using die temperature feedback" src="docs/system_schematic.light.svg">
</picture>

The die-to-fluid heat-transfer term is `(T_die - T_fluid) / R_th`. The controller raises flow when die temperature rises above its setpoint and limits the command to the specified pump envelope.

## Governing equations

The two thermal capacitance states follow the lumped energy balances:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/equations/thermal_balance.dark.svg">
  <img alt="Die and coolant-pass transient energy balance equations" src="docs/equations/thermal_balance.light.svg">
</picture>

The requested flow is a PID command around a nominal flow, with saturation:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/equations/pid_control.dark.svg">
  <img alt="Temperature error and saturated PID command for coolant mass flow" src="docs/equations/pid_control.light.svg">
</picture>

The derivative term acts on measured die temperature, avoiding derivative kick when a setpoint changes. Integral accumulation is conditionally disabled when the actuator is saturated in the same direction as the error. Pump power uses a normalized cubic affinity-law approximation:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/equations/pump_power.dark.svg">
  <img alt="Cubic hydraulic scaling for pump power" src="docs/equations/pump_power.light.svg">
</picture>

This is a system-level scaling model, not a pump curve or a measured facility power model.

The equation artwork is generated from LaTeX with `latex` and `dvisvgm`. To regenerate both color variants after editing the source equations, run `powershell -ExecutionPolicy Bypass -File scripts/render_equations.ps1` from the project root. GitHub's `<picture>` support selects the matching SVG for the reader's light or dark color scheme.

## Numerical implementation

`thermal_dynamics!(du, u, p, t)` follows Julia's in-place ODE convention: it writes the derivatives into the caller-provided `du` vector and returns no newly allocated derivative array. This reduces repeated allocations during the many right-hand-side evaluations made by an adaptive integrator. The solver state is `[T_die, T_fluid, integral_error]`; the third state carries the PID integral through solver steps rather than mutating hidden controller memory. With concrete `Float64` parameters and telemetry vectors, the hot RHS path avoids constructing temporary heap objects. The full solve is not claimed to be allocation-free: solver bookkeeping, interpolation, and saved output allocate as needed.

The workload power is linearly interpolated between telemetry samples. `run_simulation` integrates the coupled states with DifferentialEquations.jl's `Tsit5()` explicit Runge–Kutta method and saves at telemetry timestamps.

## Full-speed versus modulated cooling

At fixed pump hardware and operating regime, hydraulic power is approximated as proportional to flow cubed. Running continuously at maximum flow can provide the largest immediate cooling margin, but incurs the maximum modeled pumping draw even during low-load periods. PID modulation can reduce flow during lighter compute intervals; because of the cubic relationship, a fractional flow reduction produces a larger fractional pump-power reduction. For example, half rated flow corresponds to one eighth of rated pump power in this idealized relation.

Dynamic flow also brings trade-offs: controller tuning affects overshoot and recovery; saturation can limit cooling during sharp workload spikes; lower flow changes coolant temperature rise; and actual pump efficiency, minimum stable pump operation, valve losses, and facility controls are not represented. Compare strategies with the same workload and thermal constraints before treating modeled savings as operational savings. A simple full-speed reference energy is `P_pump_max_W * duration_seconds / 3.6e6` kWh.

## Install and run

From the project directory with Julia installed:

```julia
using Pkg
Pkg.instantiate()
Pkg.test()
```

Run the synthetic benchmark:

```sh
julia --project=. scripts/run_demo.jl
```

Run with a telemetry file:

```sh
julia --project=. scripts/run_demo.jl path/to/telemetry.csv
```

CSV input must have numeric `time_s` and `p_it_W` columns, at least two rows, strictly increasing times, and nonnegative finite power values. The demo prints integrated IT/pump energies and thermal/flow extrema, then writes `output/thermal_transient.png`.

## Parameters and scope

`SimulationParams()` provides SI-valued defaults, including a 70 °C die setpoint and physical flow limits. Construct it with keyword overrides to explore thermal mass, resistance, coolant properties, PID gains, initial conditions, pump rating, or solver tolerances. This is a two-node lumped model for education and system-level trade studies; it does not resolve spatial temperature gradients, rack-to-rack manifold hydraulics, boiling, flow maldistribution, or detailed pump/control hardware.
