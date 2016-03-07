#include "chrono_parallel/math/sse.h"
#include "chrono_parallel/math/simd.h"
#include "chrono_parallel/math/real3.h"

namespace chrono {

//========================================================
CUDA_HOST_DEVICE real3 operator+(const real3& a, const real3& b) {
    return simd::Add(a, b);
}
CUDA_HOST_DEVICE real3 operator-(const real3& a, const real3& b) {
    return simd::Sub(a, b);
}
CUDA_HOST_DEVICE real3 operator*(const real3& a, const real3& b) {
    return simd::Mul(a, b);
}
CUDA_HOST_DEVICE real3 operator/(const real3& a, const real3& b) {
    return simd::Div(a, b);
}
//========================================================
CUDA_HOST_DEVICE real3 operator+(const real3& a, real b) {
    return simd::Add(a, real3::Set(b));
}
CUDA_HOST_DEVICE real3 operator-(const real3& a, real b) {
    return simd::Sub(a, real3::Set(b));
}
CUDA_HOST_DEVICE real3 operator*(const real3& a, real b) {
    return simd::Mul(a, real3::Set(b));
}
CUDA_HOST_DEVICE real3 operator/(const real3& a, real b) {
    return simd::Div(a, real3::Set(b));
}
CUDA_HOST_DEVICE real3 operator*(real lhs, const real3& rhs) {
    return simd::Mul(real3::Set(lhs), rhs);
}
CUDA_HOST_DEVICE real3 operator/(real lhs, const real3& rhs) {
    return simd::Div(real3::Set(lhs), rhs);
}
CUDA_HOST_DEVICE real3 operator-(const real3& a) {
    return simd::Negate(a);
}
//========================================================

CUDA_HOST_DEVICE real Dot(const real3& v1, const real3& v2) {
    return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z;
    // return simd::Dot3(v1, v2);
}
CUDA_HOST_DEVICE real Dot(const real3& v) {
    return v.x * v.x + v.y * v.y + v.z * v.z;
    // return simd::Dot3(v);
}

CUDA_HOST_DEVICE real3 Normalize(const real3& v) {
    // return simd::Normalize3(v);
    return v / Sqrt(Dot(v));
}
CUDA_HOST_DEVICE real Length(const real3& v) {
    return Sqrt(Dot(v));
    // return simd::Length3(v);
}
CUDA_HOST_DEVICE real3 Sqrt(const real3& v) {
    return simd::SquareRoot(v);
}
CUDA_HOST_DEVICE real3 Cross(const real3& b, const real3& c) {
    return simd::Cross3(b.array, c.array);
}
CUDA_HOST_DEVICE real3 Abs(const real3& v) {
    return simd::Abs(v);
}
CUDA_HOST_DEVICE real3 Sign(const real3& v) {
    return simd::Max(simd::Min(v, real3::Set(1)), real3::Set(-1));
}
CUDA_HOST_DEVICE real3 Max(const real3& a, const real3& b) {
    return simd::Max(a, b);
}

CUDA_HOST_DEVICE real3 Min(const real3& a, const real3& b) {
    return simd::Min(a, b);
}

CUDA_HOST_DEVICE real3 Max(const real3& a, const real& b) {
    return simd::Max(a, real3::Set(b));
}

CUDA_HOST_DEVICE real3 Min(const real3& a, const real& b) {
    return simd::Min(a, real3::Set(b));
}
CUDA_HOST_DEVICE real Max(const real3& a) {
    return simd::Max(a);
}
CUDA_HOST_DEVICE real Min(const real3& a) {
    return simd::Min(a);
}
CUDA_HOST_DEVICE real3 Clamp(const real3& a, const real3& clamp_min, const real3& clamp_max) {
    return simd::Max(clamp_min, simd::Min(a, clamp_max));
}
CUDA_HOST_DEVICE bool operator<(const real3& a, const real3& b) {
    if (a.x < b.x) {
        return true;
    }
    if (b.x < a.x) {
        return false;
    }
    if (a.y < b.y) {
        return true;
    }
    if (b.y < a.y) {
        return false;
    }
    if (a.z < b.z) {
        return true;
    }
    if (b.z < a.z) {
        return false;
    }
    return false;
}
CUDA_HOST_DEVICE bool operator>(const real3& a, const real3& b) {
    if (a.x > b.x) {
        return true;
    }
    if (b.x > a.x) {
        return false;
    }
    if (a.y > b.y) {
        return true;
    }
    if (b.y > a.y) {
        return false;
    }
    if (a.z > b.z) {
        return true;
    }
    if (b.z > a.z) {
        return false;
    }
    return false;
}
CUDA_HOST_DEVICE bool operator==(const real3& a, const real3& b) {
    return (a[0] == b[0]) && (a[1] == b[1]) && (a[2] == b[2]);
    // return simd::IsEqual(a, b);
}
CUDA_HOST_DEVICE real3 Round(const real3& v) {
    return simd::Round(v);
}
CUDA_HOST_DEVICE bool IsZero(const real3& v) {
    return simd::IsZero(v, C_EPSILON);
}
CUDA_HOST_DEVICE real3 OrthogonalVector(const real3& v) {
    real3 abs = Abs(v);
    if (abs.x < abs.y) {
        return abs.x < abs.z ? real3(0, v.z, -v.y) : real3(v.y, -v.x, 0);
    } else {
        return abs.y < abs.z ? real3(-v.z, 0, v.x) : real3(v.y, -v.x, 0);
    }
}
CUDA_HOST_DEVICE real3 UnitOrthogonalVector(const real3& v) {
    return Normalize(OrthogonalVector(v));
}
}