module TestAlgebra

using Test
using LinearAlgebra
using CovarianceFunctions: AbstractKernel, IsotropicKernel, ismercer, isstationary, isisotropic

using CovarianceFunctions
using CovarianceFunctions: Constant, EQ, RQ, Exp, γExp, Delta, Cosine, MaternP, Matern#, SM
using CovarianceFunctions: separable, gramian
using LinearAlgebraExtensions: grid
using KroneckerProducts: KroneckerProduct

# TODO:
# test SymmetricKernel
# test higher input dimensions
# test type stability
@testset "stationary kernels" begin

    k1 = EQ()
    k2 = Matern(5*rand())
    k3 = CovarianceFunctions.Dot()

    @test typeof(k1 * k3) <: AbstractKernel
    @test ismercer(k1 * k3)
    # evaluations
    x = randn()
    y = randn()
    # sum
    @test k1(x, y) + k2(x, y) ≈ (k1+k2)(x, y)
    @test k1(x, y) + k2(x, y) ≈ (k2+k1)(x, y)
    @test k1(x, y) + k3(x, y) ≈ (k1+k3)(x, y)
    @test k1(x, y) + k3(x, y) ≈ (k3+k1)(x, y)

    # product
    @test k1(x, y) * k2(x, y) ≈ (k1*k2)(x, y)
    @test k1(x, y) * k2(x, y) ≈ (k2*k1)(x, y)
    @test k1(x, y) * k3(x, y) ≈ (k1*k3)(x, y)
    @test k1(x, y) * k3(x, y) ≈ (k3*k1)(x, y)

    # scalar test
    a = exp(randn())
    @test a*k1(x, y) ≈ (a*k1)(x, y)
    @test a*k1(x, y) ≈ (k1*a)(x, y)
    @test a + k1(x, y) ≈ (a+k1)(x, y)
    @test a + k1(x, y) ≈ (k1+a)(x, y)

    # power
    for p = 1:4
        @test k1(x, y)^p ≈ (k1^p)(x, y)
        @test k2(x, y)^p ≈ (k2^p)(x, y)
        @test k3(x, y)^p ≈ (k3^p)(x, y)
    end

    # TODO: Test invalid inputs for Power kernels
    # k_strings = ["Exponentiated Quadratic", "Exponential", "δ",
    #             "Constant", "Rational Quadratic",
    #             "γ-Exponential", "Cosine",
    #             "Matern"]#, "Spectral Mixture"]

    # T = Float64
    # k_arr = [EQ(), Exp(), Delta(),
    #         Constant(r), RQ(r),
    #         γExp(r), Cosine(r),
    #         Matern(r)]#, SM]
    # n = 16
    # d = 1
    # x = randn(T, n)
    # Σ = zeros(T, (n, n))
end

@testset "separable kernels" begin
    k = CovarianceFunctions.EQ()
    k = separable(*, k, k, k)
    h = separable(^, CovarianceFunctions.EQ(), 3)
    @test typeof(k) == typeof(h)
    x = randn(3)
    g = grid(x, x, x)
    @test gramian(k, g) isa KroneckerProduct

    y = randn(3, 4)
    g = grid(x, y)
    G = gramian(k, g)
    @test G isa KroneckerProduct
end

end # TestAlgebra

# moving to trait-based system ...
# @test typeof(k1 + k2) <: IsotropicKernel
# @test typeof(k1 * k2) <: IsotropicKernel
# @test typeof(k2 * k1) <: IsotropicKernel
# for p = 2:4
#     @test typeof(k1^p) <: IsotropicKernel
#     @test typeof(k2^p) <: IsotropicKernel
#     @test typeof(float(p)*k1) <: IsotropicKernel
# end
