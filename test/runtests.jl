using Test
using DataCenterThermalSim

@testset "DataCenterThermalSim first principles" begin
    @testset "steady-state energy balance" begin
        flow = 0.12
        params = SimulationParams(m_dot_nominal_kg_s=flow, Kp_kg_s_K=0.0,
                                  Ki_kg_s_K_s=0.0, Kd_kg_s_s_K=0.0,
                                  T_setpoint_C=70.0)
        load = 12_000.0
        T_fluid = params.T_inlet_C + load / (flow * params.cp_J_kgK)
        T_die = T_fluid + load * params.R_th_K_W
        profile = TelemetryProfile([0.0, 10.0], [load, load])
        du = zeros(3)
        thermal_dynamics!(du, [T_die, T_fluid, 0.0],
                          (params=params, profile=profile), 1.0)
        @test du[1] ≈ 0.0 atol=1e-12
        @test du[2] ≈ 0.0 atol=1e-12
        @test load ≈ flow * params.cp_J_kgK * (T_fluid - params.T_inlet_C)
    end

    @testset "temperature response and actuator bounds" begin
        params = SimulationParams()
        profile = generate_benchmark_profile(120.0)
        sol = run_simulation(params, profile)
        @test minimum(sol[1, :]) >= params.T_inlet_C - 1e-8
        @test minimum(sol[2, :]) >= params.T_inlet_C - 1e-8
        for i in eachindex(sol.t)
            dT_die = (profile.power_W[i] -
                      (sol[1, i] - sol[2, i]) / params.R_th_K_W) / params.C_die_J_K
            flow = controlled_mass_flow(params, sol[1, i], dT_die, sol[3, i])
            @test params.m_dot_min_kg_s <= flow <= params.m_dot_max_kg_s
        end
    end

    @testset "telemetry validation" begin
        @test_throws ArgumentError TelemetryProfile([0.0, 1.0], [1.0])
        @test_throws ArgumentError TelemetryProfile([0.0, 0.0], [1.0, 2.0])
        @test_throws ArgumentError TelemetryProfile([0.0, 1.0], [1.0, -2.0])
        mktemp() do path, io
            write(io, "time_s,p_it_W\n0,5000\n1,30000\n")
            close(io)
            profile = load_telemetry_csv(path)
            @test profile.time_s == [0.0, 1.0]
            @test profile.power_W == [5000.0, 30000.0]
        end
    end
end
