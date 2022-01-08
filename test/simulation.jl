# Run a typical simulation
@testset "Simulation" begin
    # Lid-Driven Cavity case (LDC).

    # Floating point type for simulations
    T = Float64

    # Spatial dimension
    N = 3

    # Case information
    name = "LDC"
    case = Case()

    ## Viscosity model
    viscosity_model = LaminarModel{T}(; Re = 1000)
    # viscosity_model = KEpsilonModel{T}(; Re = 1000)
    # viscosity_model = MixingLengthModel{T}(; Re = 1000)
    # viscosity_model = SmagorinskyModel{T}(; Re = 1000)
    # viscosity_model = QRModel{T}(; Re = 1000)

    ## Convection model
    convection_model = NoRegConvectionModel{T}()
    # convection_model = C2ConvectionModel{T}()
    # convection_model = C4ConvectionModel{T}()
    # convection_model = LerayConvectionModel{T}()

    # Grid parameters
    grid = create_grid(
        T,
        N;
        Nx = 25,                      # Number of x-volumes
        Ny = 25,                      # Number of y-volumes
        Nz = 10,                      # Number of z-volumes
        xlims = (0, 1),               # Horizontal limits (left, right)
        ylims = (0, 1),               # Vertical limits (bottom, top)
        zlims = (-0.2, 0.2),          # Depth limits (back, front)
        stretch = (1, 1, 1)          # Stretch factor (sx, sy[, sz])
    )

    # Solver settings
    solver_settings = SolverSettings{T}(;
        pressure_solver = DirectPressureSolver{T}(),    # Pressure solver
        # pressure_solver = CGPressureSolver{T}(),      # Pressure solver
        # pressure_solver = FourierPressureSolver{T}(), # Pressure solver
        p_initial = true,                               # Calculate compatible IC for the pressure
        p_add_solve = true,                             # Additional pressure solve for second order pressure
        nonlinear_acc = 1e-10,                          # Absolute accuracy
        nonlinear_relacc = 1e-14,                       # Relative accuracy
        nonlinear_maxit = 10,                           # Maximum number of iterations
        # "no": Replace iteration matrix with I/Δt (no Jacobian)
        # "approximate": Build Jacobian once before iterations only
        # "full": Build Jacobian at each iteration
        nonlinear_Newton = "approximate",
        Jacobian_type = "newton",                       # Linearization: "picard", "newton"
        nonlinear_startingvalues = false,               # Extrapolate values from last time step to get accurate initial guess (for unsteady problems only)
        nPicard = 2                                    # Number of Picard steps before switching to Newton when linearization is Newton (for steady problems only)
    )

    # Boundary conditions
    bc_unsteady = false
    bc_type = (;
        u = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
        v = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
        w = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
        k = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
        e = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
        ν = (;
            x = (:dirichlet, :dirichlet),
            y = (:dirichlet, :dirichlet),
            z = (:dirichlet, :dirichlet),
        ),
    )
    u_bc(x, y, z, t, setup) = y ≈ setup.grid.ylims[2] ? 1.0 : 0.0
    v_bc(x, y, z, t, setup) = zero(x)
    w_bc(x, y, z, t, setup) = y ≈ setup.grid.ylims[2] ? 0.2 : 0.0
    bc = create_boundary_conditions(T; bc_unsteady, bc_type, u_bc, v_bc, w_bc)

    # Initial conditions
    initial_velocity_u(x, y, z) = 0
    initial_velocity_v(x, y, z) = 0
    initial_velocity_w(x, y, z) = 0
    initial_pressure(x, y, z) = 0
    @pack! case =
        initial_velocity_u, initial_velocity_v, initial_velocity_w, initial_pressure

    # Forcing parameters
    bodyforce_u(x, y, z) = 0
    bodyforce_v(x, y, z) = 0
    bodyforce_w(x, y, z) = 0
    force = SteadyBodyForce{T}(; bodyforce_u, bodyforce_v, bodyforce_w)

    # Iteration processors
    processors = [Logger(), QuantityTracer(; nupdate = 1)]

    # Final setup
    setup = Setup{T,N}(;
        case,
        viscosity_model,
        convection_model,
        grid,
        force,
        solver_settings,
        bc,
    )

    ## Time interval
    t_start, t_end = tlims = (0.0, 0.5)

    ## Prepare
    build_operators!(setup);
    V₀, p₀ = create_initial_conditions(setup, t_start);

    ## Solve steady state problem
    problem = SteadyStateProblem(setup, V₀, p₀)
    V, p = @time solve(problem; processors)
    
    # Check that solution did not explode
    @test all(!isnan, V)
    @test all(!isnan, p)

    ## Solve unsteady problem
    problem = UnsteadyProblem(setup, V₀, p₀, tlims)
    V, p = @time solve(problem, RK44(); Δt = 0.01, processors)

    # Check that solution did not explode
    @test all(!isnan, V)
    @test all(!isnan, p)
end