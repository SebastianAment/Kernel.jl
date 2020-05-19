using ToeplitzMatrices: Circulant, SymmetricToeplitz
using SparseArrays
using LinearAlgebra
using IterativeSolvers
using Kernel
using Distributions
import Base: size, getindex

struct EmbeddedToeplitz{T,S} <: AbstractMatrix{T}
    C::Circulant{T,S}
end

EmbeddedToeplitz(v) = @views EmbeddedToeplitz(Circulant([v; v[end - 1:-1:2]]))

# Computes A * b, writing over c
function mul!(c, A::EmbeddedToeplitz, b)
    z = zeros(size(A.C, 1))
    z2 = zeros(size(A.C, 1))
    @views z[1:size(A, 1), :] .= b
    mul!(z2, A.C, z)
    @views c .= z2[1:size(A, 1)]
    return c
end

function size(A::EmbeddedToeplitz) 
    n = (size(A.C, 1) + 2) ÷ 2
    return n, n
end

getindex(A::EmbeddedToeplitz, args...) = getindex(A.C, args...)

# Represents (W)(Ku)(W^T) + D
struct StructuredKernelInterpolant{T,S} <: Factorization{T}
    Ku::EmbeddedToeplitz{T,S}
    W::SparseMatrixCSC{T,Int}
    d::Vector{T}
    du::Vector{T}
end

#####
##### Construction - based on Local Quntic Interpolation
##### Fast SKI diagonal construction
##### and Eric Hans Lee's MATLAB code GP_Derivatives
#####

# n is number of training points, N is number of grid points
function interp_grid(train_pts, grid_pts)
    n = size(train_pts, 1)
    N = length(grid_pts)
    sel_pts, wt = _select_gridpoints!(zeros(Int, n, 6), zeros(n, 6), train_pts, grid_pts)
    W = spzeros(n, N)
    for i in 1:6
        for j in 1:n
            W[j, sel_pts[j, i]] = (wt[j, i] == 0 ? eps() * 10^3 : wt[j, i])
        end
    end
    return W
end

function _select_gridpoints!(idx, wt, train_vector, grid) 
    stepsize = grid[2] - grid[1]
    idx .= floor.(Int, ((train_vector .- grid[1]) ./ stepsize))
    idx .+= [-2 -1 0 1 2 3]
    idx .+= 1
    wt .= @views _lq_interp.(abs.(train_vector .- grid[idx]) ./ stepsize)
    return idx, wt
end

# Local Quintic Interpolation
# Key's Cubic Convolution Interpolation Function
function _lq_interp(δ)
    if δ <= 1
        return ((( -0.84375 * δ + 1.96875) * δ^2) - 2.125) * δ^2 + 1
    elseif δ <= 2
        term1 = (0.203125 * δ - 1.3125) * δ + 2.65625
        return ((term1 * δ - 0.875) * δ - 2.578125) * δ + 1.90625
    elseif δ <= 3
        term2 = (0.046875 * δ - 0.65625) * δ + 3.65625
        return ((term2 * δ - 10.125) * δ + 13.921875) * δ - 7.59375
    end
    return 0
end

function mul!(c, S::StructuredKernelInterpolant, x)
    c .= S.W * (S.Ku * (S.W' * x)) .+ S.d .* x
    return c
end

function get_diag!(du, Ku, W)
    rows = rowvals(W)
    vals = nonzeros(W)
    for i in 1:length(du)
        Wcol = nzrange(W, i)
        du[i] = 0
        for j in Wcol
            for k in Wcol
                rj = rows[j]
                rk = rows[k]
                du[i] += Ku[rj, rk] * vals[j] * vals[k]
            end
        end
    end
    return du
end

# k is kernel, x is a vector of data, and m is the number of grid points
function structured_kernel_interpolant(k, x, m)
    xmin = minimum(x)
    δm = (maximum(x) - xmin) / (m - 6)
    m0 = xmin - 2.5 * δm
    grid = range(m0, m0 + (m - 1) * δm, step = δm)
    G = Kernel.gramian(k, grid)
    v = G[:, 1]
    Ku = EmbeddedToeplitz(v)
    W = interp_grid(x, grid)
    d = diag(Kernel.gramian(k, x))
    du = get_diag!(similar(d), Ku, W)
    d .-= du
    return StructuredKernelInterpolant(Ku, W, d, du)
end

# Gives dimension for the given n x n matrix. Outputs a tuple of the dimensions
# of the matrix. 
size(S::StructuredKernelInterpolant) = length(S.d), length(S.d)
size(S::StructuredKernelInterpolant, d) = length(S.d) # TODO bounds check

# Left division. Equivalent to (S^-1)b. Overwrites b. Returns nothing
function ldiv!(S::StructuredKernelInterpolant, b)
    x = similar(b)
    cg!(x, S, b)
    b .= x
    return b
end

# Takes the determinent of S. Returns a scalar
det(S::StructuredKernelInterpolant) = exp(logdet(S))

# Equivalent to ln(det(S)). Returns a scalar
function logdet(S::StructuredKernelInterpolant)
    # TODO
    return 1
end


function lanczos_arpack(A, k, v; maxiter, tol)
    T = eltype(A)
    n = size(A, 1)
    mulA! = (y, x)->mul!(y, A, x) 
    id = x->x
    # in: (T, mulA!, mulB, solveSI, n, issym, iscmplx, bmat,
    #            nev, ncv, whichstr, tol, maxiter, mode, v0)
    # out: (resid, v, ldv, iparam, ipntr, workd, workl, lworkl, rwork, TOL)
    out = Arpack.aupd_wrapper(T, mulA!, id, id, n, true, false, "I",
                       1, k, "LM", tol, maxiter, 1, v)

    α = out[7][k + 1:2 * k - 1]
    β = out[7][2:k - 1]
    
    return out[2], α, β, out[1]
end

function _lanczos_logdet!(z, acc, A, k; maxiter, tol, nsamples)
    for i in 1:nsamples
        rand!(Normal(), z)
        z .= sign.(z)
        Q, α, β, resid = lanczos_arpack(A, k, z; maxiter = maxiter, tol = tol)
        T = SymTridiagonal(α, β)
        Λ = eigen(T)
        wts = Λ.vectors[1, :].^2 .* norm(z)^2
        acc += dot(wts, log.(Λ.values))
    end
    return acc / nsamples
end

# Returns the inverse of the matrix S. 
inv(S::StructuredKernelInterpolant) = ldiv!(S, Matrix(I, size(S)...))

# Returns true if S is positive definite and false otherwise. 
function isposdef(S::StructuredKernelInterpolant)
    return det(S) > 0
end


# Based on Sebastian Ament's algebra.jl file
struct RandAddProj{T,K <: Tuple{Vararg{Kernel.AbstractKernel}}} <: Kernel.MercerKernel{T}
    ks::K # kernel for input covariances
    proj::Matrix{Float64}
    weights::Vector{Float64}
    function RandAddProj(k::Tuple{Vararg{Kernel.AbstractKernel}}, weights, dataDim)
        proj = rand(Normal(), length(k), dataDim)
        T = promote_type(eltype.(k)...)
        new{T,typeof(k)}(k, proj, weights)
    end
end

function (K::RandAddProj)(x, y)
    val = zero(promote_type(eltype(x), eltype(y)))
    for (i, k) in enumerate(K.ks)
        val += K.weights[i] * k(dot(K.proj[i, :], x), dot(K.proj[i, :], y))
    end
    return val
end

