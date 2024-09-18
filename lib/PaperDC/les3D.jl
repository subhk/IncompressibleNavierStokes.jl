# # A-posteriori analysis: Large Eddy Simulation (3D)
#
# This script is used to generate results for the the paper [Agdestein2024](@citet).
#
# - Generate filtered DNS data
# - Train closure models
# - Compare filters, closure models, and projection orders
#
# The filtered DNS data is saved and can be loaded in a subesequent session.
# The learned CNN parameters are also saved.

# ## Load packages

if false                      #src
    include("src/PaperDC.jl") #src
end                           #src

using Adapt
using CUDA
using GLMakie
using CairoMakie
using IncompressibleNavierStokes
using IncompressibleNavierStokes.RKMethods
using JLD2
using LaTeXStrings
using LinearAlgebra
using Lux
using LuxCUDA
using NeuralClosure
using NNlib
using Optimisers
using PaperDC
using Random
using FFTW

# Color palette for consistent theme throughout paper
palette = (; color = ["#3366cc", "#cc0000", "#669900", "#ff9900"])

# Choose where to put output
outdir = joinpath(@__DIR__, "output", "les3D")
plotdir = "$outdir/plots"
ispath(outdir) || mkpath(outdir)
ispath(plotdir) || mkpath(plotdir)

########################################################################## #src

# ## Random number seeds
#
# Use a new RNG with deterministic seed for each code "section"
# so that e.g. training batch selection does not depend on whether we
# generated fresh filtered DNS data or loaded existing one (the
# generation of which would change the state of a global RNG).
#
# Note: Using `rng = Random.default_rng()` twice seems to point to the
# same RNG, and mutating one also mutates the other.
# `rng = Xoshiro()` creates an independent copy each time.
#
# We define all the seeds here.

seeds = (;
    dns = 123, # DNS initial conditions
    θ₀ = 234, # Initial CNN parameters
    prior = 345, # A-priori training
    post = 456, # A-posteriori training
)

########################################################################## #src

# ## Hardware selection

# Precision
T = Float32

# Device
if CUDA.functional()
    ## For running on a CUDA compatible GPU
    @info "Running on CUDA"
    ArrayType = CuArray
    CUDA.allowscalar(false)
    device = x -> adapt(CuArray, x)
    clean() = (GC.gc(); CUDA.reclaim())
else
    ## For running on CPU.
    ## Consider reducing the sizes of DNS, LES, and CNN layers if
    ## you want to test run on a laptop.
    @warn "Running on CPU"
    ArrayType = Array
    device = identity
    clean() = nothing
end

########################################################################## #src

# ## Data generation
#
# Create filtered DNS data for training, validation, and testing.

ntrajectory = 10
filenames = map(i -> "$outdir/data_$i.jld2", 1:ntrajectory)
dns_seeds = splitseed(seeds.dns, ntrajectory)

# Parameters
params = (;
    D = 3,
    lims = (T(0), T(1)),
    Re = T(4e3),
    tburn = T(0.2),
    tsim = T(2),
    savefreq = 8,
    ndns = 512,
    nles = [64],
    filters = (FaceAverage(), VolumeAverage()),
    ArrayType,
    create_psolver = psolver_spectral_lowmemory,
)

create_data = false
create_data && for (seed, filename) in zip(dns_seeds, filenames)
    @info "Creating DNS trajectory, file $(basename(filename))"
    rng = Xoshiro(seed)
    data = create_les_data(; params..., rng)
    jldsave(filename; data)
end

# Load filtered DNS data
data = load.(filenames, "data");
Base.summarysize(data) * 1e-9

data_train = data[1:8];
data_valid = data[9:9];
data_test = data[10:10];

# Build LES setup and assemble operators
setups = map(
    nles -> Setup(;
        x = ntuple(α -> range(params.lims..., params.nles[1] + 1), params.D),
        params.Re,
        params.ArrayType,
    ),
    params.nles,
)

# Create input/output arrays for a-priori training (ubar vs c)
io_train = create_io_arrays(data_train, setups);
io_valid = create_io_arrays(data_valid, setups);
io_test = create_io_arrays(data_test, setups);

# ### Plot data

let
    u = data_train[1].data[1, 1].u
    t = data_train[1].t
    i = 17
    # function field(u)
    #     ux = u[1][1:end-1, :, i]
    #     uy = u[2][:, 1:end-1, i]
    #     ω = -diff(ux; dims = 2) + diff(uy; dims = 1)
    # end
    # function field(u)
    #     ex = u[1][:, :, i] .^2
    #     ey = u[2][:, :, i] .^2
    #     sqrt.(ex .+ ey)
    # end
    field(u) = u[1][:, :, i]
    o = Observable(field(u[1]))
    fig = heatmap(o)
    display(fig)
    tprev = T(0)
    for (t, u) in zip(t, u)
        Δt = t - tprev
        o[] = field(u)
        sleep(2 * Δt)
        tprev = t
        display(fig)
        sleep(0.05)
    end
end

let
    i = 1
    u = data_train[i].data[1, 1].u
    t = data_train[i].t
    o = Observable(u[1][1])
    volume(o) |> display
    tprev = T(0)
    for (t, u) in zip(t, u)
        Δt = t - tprev
        o[] = u[1]
        sleep(2 * Δt)
        tprev = t
    end
end

########################################################################## #src

# ## CNN closure model

# Random number generator for initial CNN parameters.
# All training sessions will start from the same θ₀
# for a fair comparison.

# CNN architecture
closure, θ₀ = cnn(;
    setup = setups[1],
    radii = [2, 2, 2, 2],
    channels = [12, 12, 12, params.D],
    activations = [tanh, tanh, tanh, identity],
    use_bias = [true, true, true, false],
    rng = Xoshiro(seeds.θ₀),
);
closure.chain

# Give the CNN a test run
# Note: Data and parameters are stored on the CPU, and
# must be moved to the GPU before running (`device`)
closure(device(io_train[1, 1].u[:, :, :, :, 1:50]), device(θ₀));

using NeuralClosure.Zygote

g = let
    u = device(io_train[1, 1].u[:, :, :, :, 1:50])
    θ = device(θ₀)
    g, = gradient(θ -> sum(closure(u, θ)), θ)
    Array(g)
end

########################################################################## #src

# ## Training

# ### A-priori training
#
# Train one set of CNN parameters for each of the filter types and grid sizes.
# Use the same batch selection random seed for each training setup.
# Save parameters to disk after each run.
# Plot training progress (for a validation data batch).

# Parameter save files
priorfiles = map(CartesianIndices(io_train)) do I
    ig, ifil = I.I
    "$outdir/prior_ifilter$(ifil)_igrid$(ig).jld2"
end

# Train
let
    ngrid, nfilter = size(io_train)
    for ifil = 1:nfilter, ig = 1:ngrid
        clean()
        starttime = time()
        @info "Training a-priori for ig = $ig, ifil = $ifil"
        trainseed, validseed = splitseed(seeds.prior, 2) # Same seed for all training setups
        dataloader = create_dataloader_prior(
            io_train[ig, ifil];
            batchsize = 50,
            device,
            rng = Xoshiro(trainseed),
        )
        θ = T(1.0e0) * device(θ₀)
        loss = create_loss_prior(mean_squared_error, closure)
        opt = Adam(T(1.0e-3))
        optstate = Optimisers.setup(opt, θ)
        it = rand(Xoshiro(validseed), 1:size(io_valid[ig, ifil].u, params.D + 2), 50)
        validset = device(map(v -> v[:, :, :, :, it], io_valid[ig, ifil]))
        (; callbackstate, callback) = create_callback(
            create_relerr_prior(closure, validset...);
            θ,
            displayref = true,
            display_each_iteration = true, # Set to `true` if using CairoMakie
        )
        (; optstate, θ, callbackstate) = train(
            dataloader,
            loss,
            optstate,
            θ;
            niter = 10_000,
            ncallback = 20,
            callbackstate,
            callback,
        )
        θ = callbackstate.θmin # Use best θ instead of last θ
        prior = (; θ = Array(θ), comptime = time() - starttime, callbackstate.hist)
        jldsave(priorfiles[ig, ifil]; prior)
    end
    clean()
end

# Load learned parameters and training times
prior = load.(priorfiles, "prior")
θ_cnn_prior = [copyto!(device(θ₀), p.θ) for p in prior];

# Check that parameters are within reasonable bounds
θ_cnn_prior .|> extrema

# Training times
map(p -> p.comptime, prior)
map(p -> p.comptime, prior) |> vec
map(p -> p.comptime, prior) |> sum # Seconds
map(p -> p.comptime, prior) |> sum |> x -> x / 60 # Minutes
map(p -> p.comptime, prior) |> sum |> x -> x / 3600 # Hours

########################################################################## #src

# ### A-posteriori training
#
# Train one set of CNN parameters for each
# projection order, filter type and grid size.
# Use the same batch selection random seed for each training setup.
# Save parameters to disk after each combination.
# Plot training progress (for a validation data batch).
#
# The time stepper `RKProject` allows for choosing when to project.

# Parameter save files
postfiles = map(CartesianIndices((size(io_train)..., 2))) do I
    ig, ifil, iorder = I.I
    "$outdir/post_iorder$(iorder)_ifil$(ifil)_ig$(ig).jld2"
end

# Train
let
    ngrid, nfilter = size(io_train)
    for iorder = 1:2, ifil = 1:nfilter, ig = 1:ngrid
        clean()
        starttime = time()
        @info "Training a-posteriori for iorder = $iorder, ifil = $ifil, ig = $ig"
        projectorder = ProjectOrder.T(iorder)
        rng = Xoshiro(seeds.post) # Same seed for all training setups
        setup = setups_train[ig]
        psolver = psolver_spectral(setup)
        loss = create_loss_post(;
            setup,
            psolver,
            method = RKProject(RK44(; T), projectorder),
            closure,
            nupdate = 2, # Time steps per loss evaluation
        )
        data = [(; u = d.data[ig, ifil].u, d.t) for d in data_train]
        dataloader = create_dataloader_post(data; device, nunroll = 20, rng)
        θ = copy(θ_cnn_prior[ig, ifil])
        opt = Adam(T(1.0e-3))
        optstate = Optimisers.setup(opt, θ)
        it = 1:30
        data = data_valid[1]
        data = (; u = device.(data.data[ig, ifil].u[it]), t = data.t[it])
        (; callbackstate, callback) = create_callback(
            create_relerr_post(;
                data,
                setup,
                psolver,
                method = RKProject(RK44(; T), projectorder),
                closure_model = wrappedclosure(closure, setup),
                nupdate = 2,
            );
            θ,
            displayref = false,
        )
        (; optstate, θ, callbackstate) = train(
            dataloader,
            loss,
            optstate,
            θ;
            niter = 2000,
            ncallback = 10,
            callbackstate,
            callback,
        )
        θ = callbackstate.θmin # Use best θ instead of last θ
        post = (; θ = Array(θ), comptime = time() - starttime)
        jldsave(postfiles[iorder, ifil, ig]; post)
    end
    clean()
end

# Load learned parameters and training times
post = load.(postfiles, "post");
θ_cnn_post = [copyto!(device(θ₀), p.θ) for p in post];

# Check that parameters are within reasonable bounds
θ_cnn_post .|> extrema

# Training times
map(p -> p.comptime, post)
map(p -> p.comptime, post) |> x -> reshape(x, 6, 2)
map(p -> p.comptime, post) ./ 60
map(p -> p.comptime, post) |> sum
map(p -> p.comptime, post) |> sum |> x -> x / 60
map(p -> p.comptime, post) |> sum |> x -> x / 3600

########################################################################## #src

# ### Train Smagorinsky model
#
# Use a-posteriori error grid search to determine
# the optimal Smagorinsky constant.
# Find one constant for each projection order and filter type. but
# The constant is shared for all grid sizes, since the filter
# width (=grid size) is part of the model definition separately.

smag = map(CartesianIndices((size(io_train, 2), 2))) do I
    starttime = time()
    ifil, iorder = I.I
    ngrid = size(io_train, 1)
    θmin = T(0)
    emin = T(Inf)
    isample = 1
    it = 1:50
    for θ in LinRange(T(0), T(0.5), 501)
        e = T(0)
        for igrid = 1:ngrid
            println("iorder = $iorder, ifil = $ifil, θ = $θ, igrid = $igrid")
            setup = setups_train[igrid]
            psolver = psolver_spectral(setup)
            d = data_train[isample]
            data = (; u = device.(d.data[igrid, ifil].u[it]), t = d.t[it])
            nupdate = 4
            err = create_relerr_post(;
                data,
                setup,
                psolver,
                method = RKProject(RK44(; T), projectorder),
                closure_model = IncompressibleNavierStokes.smagorinsky_closure(setup),
                nupdate,
            )
            e += err(θ)
        end
        e /= ngrid
        if e < emin
            emin = e
            θmin = θ
        end
    end
    (; θ = θmin, comptime = time() - starttime)
end
clean()

smag

# Save trained parameters
jldsave("$outdir/smag.jld2"; smag);

# Load trained parameters
smag = load("$outdir/smag.jld2")["smag"];

# Extract coefficients
θ_smag = map(s -> s.θ, smag)

# Computational time
map(s -> s.comptime, smag)
map(s -> s.comptime, smag) |> sum

########################################################################## #src

# ## Prediction errors

# ### Compute a-priori errors
#
# Note that it is still interesting to compute the a-priori errors for the
# a-posteriori trained CNN.

eprior = let
    prior = zeros(T, 1, 2)
    post = zeros(T, 1, 2, 2)
    for ig = 1:1, ifil = 1:2
        println("ig = $ig, ifil = $ifil")
        testset = device(io_test[ig, ifil])
        err = create_relerr_prior(closure, testset...)
        prior[ig, ifil] = err(θ_cnn_prior[ig, ifil])
        # for iorder = 1:2
        #     post[ig, ifil, iorder] = err(θ_cnn_post[ig, ifil, iorder])
        # end
    end
    (; prior, post)
end
clean()

eprior.prior
eprior.post

eprior.prior |> x -> reshape(x, :) |> x -> round.(x; digits = 2)
eprior.post |> x -> reshape(x, :, 2) |> x -> round.(x; digits = 2)

########################################################################## #src

# ### Compute a-posteriori errors

(; e_nm, e_smag, e_cnn, e_cnn_post) = let
    e_nm = zeros(T, size(data_test[1].data)...)
    e_smag = zeros(T, size(data_test[1].data)..., 2)
    e_cnn = zeros(T, size(data_test[1].data)..., 2)
    e_cnn_post = zeros(T, size(data_test[1].data)..., 2)
    for iorder = 1:2, ifil = 1:2, ig = 1:size(data_test[1].data, 1)
        println("iorder = $iorder, ifil = $ifil, ig = $ig")
        projectorder = ProjectOrder.T(iorder)
        setup = setups[ig]
        psolver = psolver_spectral(setup)
        data = (; u = device.(data_test[1].data[ig, ifil].u), t = data_test[1].t)
        nupdate = 8
        ## No model
        ## Only for closurefirst, since projectfirst is the same
        if iorder == 2
            err = create_relerr_post(; data, setup, psolver, closure_model = nothing, nupdate)
            e_nm[ig, ifil] = err(nothing)
        end
        # ## Smagorinsky
        # err = create_relerr_post(;
        #     data,
        #     setup,
        #     psolver,
        #     method = RKProject(RK44(; T), projectorder),
        #     closure_model = smagorinsky_closure(setup),
        #     nupdate,
        # )
        # e_smag[ig, ifil, iorder] = err(θ_smag[ifil, iorder])
        ## CNN
        ## Only the first grids are trained for
        err = create_relerr_post(;
            data,
            setup,
            psolver,
            method = RKProject(RK44(; T), projectorder),
            closure_model = wrappedclosure(closure, setup),
            nupdate,
        )
        e_cnn[ig, ifil, iorder] = err(θ_cnn_prior[ig, ifil])
        # e_cnn_post[ig, ifil, iorder] = err(θ_cnn_post[ig, ifil, iorder])
    end
    (; e_nm, e_smag, e_cnn, e_cnn_post)
end
clean()

e_cnn

round.(
    [e_nm[:] reshape(e_smag, :, 2) reshape(e_cnn, :, 2) reshape(e_cnn_post, :, 2)][:, :];
    sigdigits = 2,
)

########################################################################## #src

# ### Plot a-priori errors

# Better for PDF export
CairoMakie.activate!()

fig = with_theme(; palette) do
    nles = params.nles
    ifil = 1
    fig = Figure(; size = (500, 400))
    ax = Axis(
        fig[1, 1];
        xscale = log10,
        xticks = nles,
        xlabel = "Resolution",
        title = "Relative a-priori error $(ifil == 1 ? " (FA)" : " (VA)")",
    )
    linestyle = :solid
    label = "No closure"
    scatterlines!(
        nles,
        ones(T, length(nles));
        color = Cycled(1),
        linestyle,
        marker = :circle,
        label,
    )
    label = "CNN (Lprior)"
    scatterlines!(
        nles,
        eprior.prior[:, ifil];
        color = Cycled(2),
        linestyle,
        marker = :utriangle,
        label,
    )
    # label = "CNN (Lpost, DIF)"
    # scatterlines!(
    #     nles,
    #     eprior.post[:, ifil, 1];
    #     color = Cycled(3),
    #     linestyle,
    #     marker = :rect,
    #     label,
    # )
    # label = "CNN (Lpost, DCF)"
    # scatterlines!(
    #     nles,
    #     eprior.post[:, ifil, 2];
    #     color = Cycled(4),
    #     linestyle,
    #     marker = :diamond,
    #     label,
    # )
    axislegend(; position = :lb)
    ylims!(ax, (T(-0.05), T(1.05)))
    name = "$plotdir/convergence"
    ispath(name) || mkpath(name)
    save("$name/prior_ifilter$ifil.pdf", fig)
    fig
end

########################################################################## #src

# ### Plot a-posteriori errors

# Better for PDF export
CairoMakie.activate!()

with_theme(; palette) do
    iorder = 2
    lesmodel = iorder == 1 ? "DIF" : "DCF"
    ntrain = size(data_train[1].data, 1)
    nles = params.nles
    fig = Figure(; size = (500, 400))
    ax = Axis(
        fig[1, 1];
        xscale = log10,
        yscale = log10,
        xticks = nles,
        xlabel = "Resolution",
        title = "Relative error ($lesmodel)",
    )
    for ifil = 1:2
        linestyle = ifil == 1 ? :solid : :dash
        label = "No closure"
        ifil == 2 && (label = nothing)
        scatterlines!(
            nles,
            e_nm[1:ntrain, ifil];
            color = Cycled(1),
            linestyle,
            marker = :circle,
            label,
        )
    end
    for ifil = 1:2
        linestyle = ifil == 1 ? :solid : :dash
        label = "Smagorinsky"
        ifil == 2 && (label = nothing)
        scatterlines!(
            nles,
            e_smag[1:ntrain, ifil, iorder];
            color = Cycled(2),
            linestyle,
            marker = :utriangle,
            label,
        )
    end
    for ifil = 1:2
        linestyle = ifil == 1 ? :solid : :dash
        label = "CNN (prior)"
        ifil == 2 && (label = nothing)
        scatterlines!(
            nles[1:ntrain],
            e_cnn[1:ntrain, ifil, iorder];
            color = Cycled(3),
            linestyle,
            marker = :rect,
            label,
        )
    end
    for ifil = 1:2
        linestyle = ifil == 1 ? :solid : :dash
        label = "CNN (post)"
        ifil == 2 && (label = nothing)
        scatterlines!(
            nles[1:ntrain],
            e_cnn_post[1:ntrain, ifil, iorder];
            color = Cycled(4),
            linestyle,
            marker = :diamond,
            label,
        )
    end
    axislegend(; position = :lb)
    ylims!(ax, (T(0.025), T(1.00)))
    name = "$plotdir/convergence"
    ispath(name) || mkpath(name)
    # save("$name/iorder$iorder.pdf", fig)
    fig
end

########################################################################## #src

# ## Energy evolution

# ### Compute total kinetic energy as a function of time

kineticenergy = let
    clean()
    ngrid, nfilter = size(io_train)
    template(sz...) = fill((; thist = zeros(T, 0), ehist = zeros(T, 0)), sz...)
    ke_ref = template(ngrid, nfilter)
    ke_nomodel = template(ngrid, nfilter)
    ke_smag = template(ngrid, nfilter, 2)
    ke_cnn_prior = template(ngrid, nfilter, 2)
    ke_cnn_post = template(ngrid, nfilter, 2)
    for iorder = 1:2, ifil = 1:nfilter, ig = 1:ngrid
        println("iorder = $iorder, ifil = $ifil, ig = $ig")
        projectorder = ProjectOrder.T(iorder)
        setup = setups[ig]
        psolver = psolver_spectral(setup)
        trajectory = data_test[1]
        t = trajectory.t
        ustart = trajectory.data[ig, ifil].u[1] |> device
        tlims = (t[1], t[end])
        nupdate = 2
        Δt = (t[2] - t[1]) / nupdate
        T = eltype(ustart[1])
        ewriter = processor() do state
            thist = zeros(T, 0)
            ehist = zeros(T, 0)
            on(state) do (; u, t, n)
                if n % nupdate == 0
                    e = IncompressibleNavierStokes.total_kinetic_energy(u, setup)
                    push!(thist, t)
                    push!(ehist, e)
                end
            end
            state[] = state[] # Compute initial energy
            (; thist, ehist)
        end
        processors = (; ewriter)
        if iorder == 1
            ## Does not depend on projection order
            ke_ref[ig, ifil] = (;
                thist = t,
                ehist = map(
                    u -> IncompressibleNavierStokes.total_kinetic_energy(device(u), setup),
                    trajectory.data[ig, ifil].u,
                ),
            )
            ke_nomodel[ig, ifil] =
                solve_unsteady(; setup, ustart, tlims, Δt, processors, psolver)[2].ewriter
        end
        # ke_smag[ig, ifil, iorder] =
        #     solve_unsteady(;
        #         setup = (; setup..., projectorder, closure_model = smagorinsky_closure(setup)),
        #         ustart,
        #         tlims,
        #         Δt,
        #         processors,
        #         psolver,
        #         θ = θ_smag[ifil, iorder],
        #     )[2].ewriter
        ke_cnn_prior[ig, ifil, iorder] =
            solve_unsteady(;
                setup = (;
                    setup...,
                    projectorder,
                    closure_model = wrappedclosure(closure, setup),
                ),
                ustart,
                tlims,
                Δt,
                processors,
                psolver,
                θ = θ_cnn_prior[ig, ifil],
            )[2].ewriter
        # ke_cnn_post[ig, ifil, iorder] =
        #     solve_unsteady(;
        #         setup = (; setup..., projectorder, closure_model = wrappedclosure(closure, setup)),
        #         ustart,
        #         tlims,
        #         Δt,
        #         processors,
        #         psolver,
        #         θ = θ_cnn_post[ig, ifil, iorder],
        #     )[2].ewriter
    end
    (; ke_ref, ke_nomodel, ke_smag, ke_cnn_prior, ke_cnn_post)
end;
clean();

########################################################################## #src

# ### Plot energy evolution

# Better for PDF export
CairoMakie.activate!()

with_theme(; palette) do
    for iorder = 1:2, ifil = 1:2, igrid = 1:1
        println("iorder = $iorder, ifil = $ifil, igrid = $igrid")
        lesmodel = iorder == 1 ? "DIF" : "DCF"
        fil = ifil == 1 ? "FA" : "VA"
        nles = params.nles[igrid]
        fig = Figure(; size = (500, 400))
        ax = Axis(
            fig[1, 1];
            xlabel = "t",
            ylabel = "E(t)",
            title = "Kinetic energy: $lesmodel, $fil",
            # xscale = log10,
            yscale = log10,
        )
        lines!(
            ax,
            kineticenergy.ke_ref[igrid, ifil].thist[2:end],
            kineticenergy.ke_ref[igrid, ifil].ehist[2:end];
            color = Cycled(1),
            linestyle = :dash,
            label = "Reference",
        )
        lines!(
            ax,
            kineticenergy.ke_nomodel[igrid, ifil].thist[2:end],
            kineticenergy.ke_nomodel[igrid, ifil].ehist[2:end];
            color = Cycled(1),
            label = "No closure",
        )
        # lines!(
        #     ax,
        #     t,
        #     kineticenergy.ke_smag[igrid, ifil, iorder].thist[2:end],
        #     kineticenergy.ke_smag[igrid, ifil, iorder].ehist[2:end];
        #     color = Cycled(2),
        #     label = "Smagorinsky",
        # )
        lines!(
            ax,
            kineticenergy.ke_cnn_prior[igrid, ifil, iorder].thist[2:end],
            kineticenergy.ke_cnn_prior[igrid, ifil, iorder].ehist[2:end];
            color = Cycled(3),
            label = "CNN (prior)",
        )
        # lines!(
        #     ax,
        #     t,
        #     kineticenergy.ke_cnn_post[igrid, ifil, iorder].thist[2:end],
        #     kineticenergy.ke_cnn_post[igrid, ifil, iorder].ehist[2:end];
        #     color = Cycled(4),
        #     label = "CNN (post)",
        # )
        iorder == 1 && axislegend(; position = :lt)
        iorder == 2 && axislegend(; position = :lb)
        name = "$plotdir/energy_evolution"
        ispath(name) || mkpath(name)
        # save("$(name)/iorder$(iorder)_ifilter$(ifil)_igrid$(igrid).pdf", fig)
        fig |> display
    end
end

########################################################################## #src

# ## Divergence evolution

# ### Compute divergence as a function of time

divs = let
    clean()
    ngrid, nfilter = size(io_train)
    d_ref = fill(zeros(T, 0), ngrid, nfilter)
    d_nomodel = fill(zeros(T, 0), ngrid, nfilter, 3)
    d_smag = fill(zeros(T, 0), ngrid, nfilter, 3)
    d_cnn_prior = fill(zeros(T, 0), ngrid, nfilter, 3)
    d_cnn_post = fill(zeros(T, 0), ngrid, nfilter, 3)
    for iorder = 1:3, ifil = 1:nfilter, ig = 1:ngrid
        println("iorder = $iorder, ifil = $ifil, ig = $ig")
        projectorder = ProjectOrder.T(iorder)
        setup = setups[ig]
        psolver = psolver_spectral(setup)
        t = data_test[1].t
        ustart = data_test[1].data[ig, ifil].u[1] |> device
        tlims = (t[1], t[end])
        nupdate = 2
        Δt = (t[2] - t[1]) / nupdate
        T = eltype(ustart[1])
        dwriter = processor() do state
            div = scalarfield(setup)
            dhist = zeros(T, 0)
            on(state) do (; u, n)
                if n % nupdate == 0
                    IncompressibleNavierStokes.divergence!(div, u, setup)
                    d = view(div, setup.grid.Ip)
                    d = sum(abs2, d) / length(d)
                    d = sqrt(d)
                    push!(dhist, d)
                end
            end
            state[] = state[] # Compute initial divergence
            dhist
        end
        if iorder == 1
            ## Does not depend on projection order
            d_ref[ig, ifil] = map(data_test[1].data[ig, ifil].u) do u
                u = device(u)
                div = IncompressibleNavierStokes.divergence(u, setup)
                d = view(div, setup.grid.Ip)
                d = sum(abs2, d) / length(d)
                d = sqrt(d)
            end
        end
        s(closure_model, θ) =
            solve_unsteady(;
                (; setup..., closure_model),
                ustart,
                tlims,
                method = RKProject(RK44(; T), projectorder),
                Δt,
                processors = (; dwriter),
                psolver,
                θ,
            )[2].dwriter
        iorder_use = iorder == 3 ? 2 : iorder
        d_nomodel[ig, ifil, iorder] = s(nothing, nothing)
        d_smag[ig, ifil, iorder] =
            s(smagorinsky_closure(setup), θ_smag[ifil, iorder_use])
        d_cnn_prior[ig, ifil, iorder] =
            s(wrappedclosure(closure, setup), θ_cnn_prior[ig, ifil])
        d_cnn_post[ig, ifil, iorder] =
            s(wrappedclosure(closure, setup), θ_cnn_post[ig, ifil, iorder_use])
    end
    (; d_ref, d_nomodel, d_smag, d_cnn_prior, d_cnn_post)
end;
clean();

# Check that divergence is within reasonable bounds
divs.d_ref .|> extrema
divs.d_nomodel .|> extrema
divs.d_smag .|> extrema
divs.d_cnn_prior .|> extrema
divs.d_cnn_post .|> extrema

########################################################################## #src

# ### Plot Divergence

# Better for PDF export
CairoMakie.activate!()

with_theme(;
    ## fontsize = 20,
    palette,
) do
    t = data_test[1].t
    # for islog in (true, false)
    for islog in (false,)
        for iorder = 1:2, ifil = 1:2, igrid = 1:3
            println("iorder = $iorder, ifil = $ifil, igrid = $igrid")
            lesmodel = if iorder == 1
                "DIF"
            elseif iorder == 2
                "DCF"
            elseif iorder == 3
                "DCF-RHS"
            end
            fil = ifil == 1 ? "FA" : "VA"
            nles = params_test.nles[igrid]
            fig = Figure(; size = (500, 400))
            ax = Axis(
                fig[1, 1];
                yscale = islog ? log10 : identity,
                xlabel = "t",
                title = "Divergence: $lesmodel, $fil,  $nles",
            )
            lines!(ax, t, divs.d_nomodel[igrid, ifil, iorder]; label = "No closure")
            lines!(ax, t, divs.d_smag[igrid, ifil, iorder]; label = "Smagorinsky")
            lines!(ax, t, divs.d_cnn_prior[igrid, ifil, iorder]; label = "CNN (prior)")
            lines!(ax, t, divs.d_cnn_post[igrid, ifil, iorder]; label = "CNN (post)")
            lines!(
                ax,
                t,
                divs.d_ref[igrid, ifil];
                color = Cycled(1),
                linestyle = :dash,
                label = "Reference",
            )
            iorder == 2 && ifil == 1 && axislegend(; position = :rt)
            islog && ylims!(ax, (T(1e-6), T(1e3)))
            name = "$plotdir/divergence/$mname/$(islog ? "log" : "lin")"
            ispath(name) || mkpath(name)
            save("$(name)/iorder$(iorder)_ifilter$(ifil)_igrid$(igrid).pdf", fig)
        end
    end
end

########################################################################## #src

# ## Solutions at final time

ufinal = let
    ngrid, nfilter = size(io_train)
    temp = ntuple(α -> zeros(T, 0, 0, 0), 3)
    u_ref = fill(temp, ngrid, nfilter)
    u_nomodel = fill(temp, ngrid, nfilter)
    u_smag = fill(temp, ngrid, nfilter, 3)
    u_cnn_prior = fill(temp, ngrid, nfilter, 3)
    u_cnn_post = fill(temp, ngrid, nfilter, 3)
    for iorder = 1:2, ifil = 1:nfilter, igrid = 1:ngrid
        clean()
        println("iorder = $iorder, ifil = $ifil, igrid = $igrid")
        projectorder = ProjectOrder.T(iorder)
        t = data_test[1].t
        setup = setups[igrid]
        psolver = psolver_spectral(setup)
        ustart = data_test[1].data[igrid, ifil].u[1] |> device
        tlims = (t[1], t[end])
        # nupdate = 2
        # Δt = (t[2] - t[1]) / nupdate
        T = eltype(ustart[1])
        s(closure_model, θ) =
            solve_unsteady(;
                setup = (; setup..., closure_model),
                ustart,
                tlims,
                method = RKProject(RK44(; T), projectorder),
                # Δt,
                psolver,
                θ,
            )[1].u .|> Array
        if iorder == 1
            ## Does not depend on projection order
            u_ref[igrid, ifil] = data_test[1].data[igrid, ifil].u[end]
            u_nomodel[igrid, ifil] = s(nothing, nothing)
        end
        # u_smag[igrid, ifil, iorder] =
        #     s(smagorinsky_closure(setup), θ_smag[ifil, iorder])
        u_cnn_prior[igrid, ifil, iorder] =
            s(wrappedclosure(closure, setup), θ_cnn_prior[igrid, ifil])
        # u_cnn_post[igrid, ifil, iorder] =
        #     s(wrappedclosure(closure, setup), θ_cnn_post[igrid, ifil, iorder])
    end
    (; u_ref, u_nomodel, u_smag, u_cnn_prior, u_cnn_post)
end;
clean();

## # Save solution
## jldsave("$outdir/ufinal.jld2"; ufinal)
##
## # Load solution
## ufinal = load("$outdir/ufinal.jld2")["ufinal"];

########################################################################## #src

# ### Plot spectra
#
# Plot kinetic energy spectra at final time.

# Better for PDF export
CairoMakie.activate!()

fig = with_theme(; palette) do
    for iorder = 1:2, ifil = 1:2, igrid = 1:1
        println("iorder = $iorder, ifil = $ifil, igrid = $igrid")
        lesmodel = iorder == 1 ? "DIF" : "DCF"
        fil = ifil == 1 ? "FA" : "VA"
        nles = params.nles[igrid]
        setup = setups[igrid]
        fields =
            [
                ufinal.u_ref[igrid, ifil],
                ufinal.u_nomodel[igrid, ifil],
                # ufinal.u_smag[igrid, ifil, iorder],
                ufinal.u_cnn_prior[igrid, ifil, iorder],
                # ufinal.u_cnn_post[igrid, ifil, iorder],
            ] .|> device
        (; Ip) = setup.grid
        (; A, κ, K) = IncompressibleNavierStokes.spectral_stuff(setup)
        specs = map(fields) do u
            up = u
            e = sum(up) do u
                u = u[Ip]
                uhat = fft(u)[ntuple(α -> 1:K[α], 3)...]
                abs2.(uhat) ./ (3 * prod(size(u))^2)
            end
            e = A * reshape(e, :)
            ## e = max.(e, eps(T)) # Avoid log(0)
            ehat = Array(e)
        end
        kmax = maximum(κ)
        ## Build inertial slope above energy
        krange = [T(16), T(κ[end])]
        slope, slopelabel = -T(3), L"$\kappa^{-3}$"
        slopeconst = maximum(specs[1] ./ κ .^ slope)
        offset = 3
        inertia = offset .* slopeconst .* krange .^ slope
        ## Nice ticks
        logmax = round(Int, log2(kmax + 1))
        xticks = T(2) .^ (0:logmax)
        ## Make plot
        fig = Figure(; size = (500, 400))
        ax = Axis(
            fig[1, 1];
            xticks,
            xlabel = "κ",
            xscale = log10,
            yscale = log10,
            limits = (1, kmax, T(1e-8), T(1)),
            title = "Kinetic energy: $lesmodel, $fil",
        )
        lines!(ax, κ, specs[2]; color = Cycled(1), label = "No model")
        # lines!(ax, κ, specs[3]; color = Cycled(2), label = "Smagorinsky")
        lines!(ax, κ, specs[3]; color = Cycled(3), label = "CNN (prior)")
        # lines!(ax, κ, specs[5]; color = Cycled(4), label = "CNN (post)")
        lines!(ax, κ, specs[1]; color = Cycled(1), linestyle = :dash, label = "Reference")
        lines!(ax, krange, inertia; color = Cycled(1), label = slopelabel, linestyle = :dot)
        axislegend(ax; position = :cb)
        autolimits!(ax)
        # ylims!(ax, (T(1e-3), T(0.35)))
        name = "$plotdir/energy_spectra"
        ispath(name) || mkpath(name)
        # save("$(name)/iorder$(iorder)_ifilter$(ifil)_igrid$(igrid).pdf", fig)
        display(fig)
    end
end
clean();

########################################################################## #src

# ### Plot fields

# Export to PNG, otherwise each volume gets represented
# as a separate rectangle in the PDF
# (takes time to load in the article PDF)
GLMakie.activate!()

with_theme(; fontsize = 25, palette) do
    ## Reference box for eddy comparison
    x1 = 0.3
    x2 = 0.5
    y1 = 0.5
    y2 = 0.7
    box = [
        Point2f(x1, y1),
        Point2f(x2, y1),
        Point2f(x2, y2),
        Point2f(x1, y2),
        Point2f(x1, y1),
    ]
    path = "$plotdir/les_fields/$mname"
    ispath(path) || mkpath(path)
    for iorder = 1:2, ifil = 1:2, igrid = 1:3
        setup = setups[igrid]
        name = "$path/iorder$(iorder)_ifilter$(ifil)_igrid$(igrid)"
        lesmodel = iorder == 1 ? "DIF" : "DCF"
        fil = ifil == 1 ? "FA" : "VA"
        nles = params_test.nles[igrid]
        function makeplot(u, title, suffix)
            fig = fieldplot(
                (; u, t = T(0));
                setup,
                title,
                docolorbar = false,
                size = (500, 500),
            )
            lines!(box; linewidth = 5, color = Cycled(2)) # Red in palette
            fname = "$(name)_$(suffix).png"
            save(fname, fig)
            ## run(`convert $fname -trim $fname`) # Requires imagemagick
        end
        iorder == 2 &&
            makeplot(device(ufinal.u_ref[igrid, ifil]), "Reference, $fil, $nles", "ref")
        iorder == 2 && makeplot(
            device(ufinal.u_nomodel[igrid, ifil]),
            "No closure, $fil, $nles",
            "nomodel",
        )
        makeplot(
            device(ufinal.u_smag[igrid, ifil, iorder]),
            "Smagorinsky, $lesmodel, $fil, $nles",
            "smag",
        )
        makeplot(
            device(ufinal.u_cnn_prior[igrid, ifil, iorder]),
            "CNN (prior), $lesmodel, $fil, $nles",
            "prior",
        )
        makeplot(
            device(ufinal.u_cnn_post[igrid, ifil, iorder]),
            "CNN (post), $lesmodel, $fil, $nles",
            "post",
        )
    end
end