/*
 * Copyright (c) 2013-2016 Nathaniel Jones
 * Massachusetts Institute of Technology
 */

#include <optix_world.h>
#include "optix_shader_common.h"

using namespace optix;

struct Transform
{
	optix::Matrix<3,3> m;
};

/* Program variables */
rtDeclareVariable(int, data, , ); /* texture ID */
rtDeclareVariable(int, type, , ); /* type of data (true for float) */
rtDeclareVariable(float3, org, , ); /* texture minimum coordinates */
rtDeclareVariable(float3, siz, , ); /* texture coordinates extent */
rtDeclareVariable(int3, ne, , ); /* number of elements in texture array */
rtDeclareVariable(Transform, transform, , ); /* transformation matrix */
rtDeclareVariable(float, multiplier, , ) = 1.0f; /* multiplier for light source intensity */
rtDeclareVariable(float3, bounds, , ); /* dimensions of axis-aligned box or Z-aligned cylinder in meters */

// Calculate source distribution.
RT_METHOD float3 source(const float3 dir)
{
	float phi = acosf(dir.z);
	float theta = atan2f(-dir.y, -dir.x);
	theta += 2.0f * M_PIf * (theta < 0.0f);

	/* Normalize to [0, 1] within range */
	phi = (180.0f * M_1_PIf * phi - org.x) / siz.x;
	theta = (180.0f * M_1_PIf * theta - org.y) / siz.y;

	/* Renormalize to remove edges */
	phi = (phi * (ne.x - 1) + 0.5f) / ne.x;
	theta = (theta * (ne.y - 1) + 0.5f) / ne.y;

	if (type)
		return make_float3(multiplier * rtTex2D<float>(data, phi, theta)); // this is corr from source.cal
	return multiplier * make_float3(rtTex2D<float4>(data, phi, theta));
}

// Calculate source distribution.
RT_CALLABLE_PROGRAM float3 corr(const float3 direction, const float3 ignore)
{
	const float3 dir = transform.m * direction;
	return source(dir); // this is corr from source.cal
}

// Calculate source distribution with correction for flat sources.
RT_CALLABLE_PROGRAM float3 flatcorr(const float3 direction, const float3 normal)
{
	const float3 dir = transform.m * direction;
	const float rdot = dot(direction, normal);
	return source(dir) / fabsf(rdot); // this is flatcorr from source.cal
}

// Calculate source distribution with correction for emitting boxes.
RT_CALLABLE_PROGRAM float3 boxcorr(const float3 direction, const float3 ignore)
{
	const float3 dir = transform.m * direction;
	const float boxprojection = fabs(dir.x) * bounds.y * bounds.z + fabs(dir.y) * bounds.x * bounds.z + fabs(dir.z) * bounds.x * bounds.y;
	return source(dir) / boxprojection; // this is boxcorr from source.cal
}

// Calculate source distribution with correction for emitting cylinders.
RT_CALLABLE_PROGRAM float3 cylcorr(const float3 direction, const float3 ignore)
{
	const float3 dir = transform.m * direction;
	const float cylprojection = bounds.x * bounds.y * sqrtf(fmaxf(1.0f - dir.z * dir.z, 0.0f)) + M_PIf / 4.0f * bounds.x * bounds.x * fabs(dir.z);
	return source(dir) / cylprojection; // this is cylcorr from source.cal
}