/*
 * Copyright (c) 2013-2014 Nathaniel Jones
 * Massachusetts Institute of Technology
 */

#include <optix_world.h>
#include "optix_shader_common.h"

using namespace optix;

/* Program variables */
rtDeclareVariable(unsigned int,  camera, , );
rtDeclareVariable(float3,        eye, , );
rtDeclareVariable(float3,        U, , ); /* view.hvec */
rtDeclareVariable(float3,        V, , ); /* view.vvec */
rtDeclareVariable(float3,        W, , ); /* view.vdir */
rtDeclareVariable(float2,        fov, , );
rtDeclareVariable(float2,        shift, , );
rtDeclareVariable(float2,        clip, , );
rtDeclareVariable(float,         dstrpix, , ); /* Pixel sample jitter (-pj) */

/* Contex variables */
rtBuffer<float4, 2>              output_buffer;
//rtBuffer<unsigned int, 2>        rnd_seeds;
rtDeclareVariable(rtObject,      top_object, , );
rtDeclareVariable(unsigned int,  radiance_ray_type, , );

/* OptiX variables */
rtDeclareVariable(uint2, launch_index, rtLaunchIndex, );
rtDeclareVariable(uint2, launch_dim,   rtLaunchDim, );
rtDeclareVariable(float, time_view_scale, , ) = 1e-6f;

//#define TIME_VIEW


// Initialize the random state
static __device__ void init_state( PerRayData_radiance* prd )
{
	rand_state state;
	prd->state = &state;
	curand_init( launch_index.x + launch_dim.x * launch_index.y, 0, 0, prd->state );
}

// Pick the ray direction based on camera type as in image.c.
RT_PROGRAM void image_camera()
{
#ifdef TIME_VIEW
	clock_t t0 = clock();
	output_buffer[launch_index] = make_float4( t0 );
#endif
	PerRayData_radiance prd;
	init_state( &prd );

	float2 d = make_float2( curand_uniform( prd.state ), curand_uniform( prd.state ) );
	d = 0.5f + dstrpix * ( 0.5f - d ); // this is pixjitter() from rpict.c
	d = shift + ( make_float2( launch_index ) + d ) / make_float2( launch_dim ) - 0.5f;
	float3 ray_origin = eye;
	float z = 1.0f;

	// This is adapted from viewray() in image.c.
  	if( camera == VT_PAR ) { /* parallel view */
		ray_origin += d.x*U + d.y*V;
		d = make_float2( 0.0f );
	} else if ( camera == VT_HEM ) { /* hemispherical fisheye */
		z = 1.0f - d.x*d.x * dot( U, U ) - d.y*d.y * dot( V, V );
		if (z < 0.0f) {
			output_buffer[launch_index] = make_float4( 0.0f );//TODO throw an exception?
			return;
		}
		z = sqrtf(z);
	} else if ( camera == VT_CYL ) { /* cylindrical panorama */
		float dd = d.x * fov.x * ( M_PIf / 180.0f );
		z = cosf( dd );
		d.x = sinf( dd );
	} else if ( camera == VT_ANG ) { /* angular fisheye */
		d *= fov / 180.0f;
		float dd = sqrtf( dot( d, d ) );
		if (dd > 1.0f) {
			output_buffer[launch_index] = make_float4( 0.0f );//TODO throw an exception?
			return;
		}
		z = cosf( M_PIf * dd );
		d *= sqrtf( 1.0f - z*z ) / dd;
	} else if ( camera == VT_PLS ) { /* planispheric fisheye */
		d *= make_float2( sqrtf( dot( U, U ) ), sqrtf( dot( V, V ) ) );
		float dd = dot( d, d );
		z = ( 1.0f - dd ) / ( 1.0f + dd );
		d *= 1.0f + z;
	}

	float3 ray_direction = normalize(d.x*U + d.y*V + z*W);

	// Zero or negative aft clipping distance indicates infinity
	float aft = clip.y;
	if (aft <= FTINY) {
		aft = RAY_END;
	}

	Ray ray = make_Ray(ray_origin, ray_direction, radiance_ray_type, clip.x, aft);

	prd.weight = 1.0f;
	prd.depth = 0;
	prd.ambient_depth = 0;
	//prd.seed = rnd_seeds[launch_index];
#ifdef FILL_GAPS
	prd.primary = 1;
#endif
#ifdef RAY_COUNT
	prd.ray_count = 1;
#endif

	rtTrace(top_object, ray, prd);

#ifdef TIME_VIEW
	clock_t t1 = clock();
 
	float expected_fps   = 1.0f;
	float pixel_time     = ( t1 - t0 ) * time_view_scale * expected_fps;
	output_buffer[launch_index] = make_float4( pixel_time );
#elif defined RAY_COUNT
	output_buffer[launch_index] = make_float4( make_float3( prd.ray_count ), prd.distance );
#else
	output_buffer[launch_index] = make_float4( prd.result, prd.distance );
#endif
}

RT_PROGRAM void exception()
{
	const unsigned int code = rtGetExceptionCode();
	rtPrintf( "Caught exception 0x%X at launch index (%d,%d)\n", code, launch_index.x, launch_index.y );
#ifdef TIME_VIEW
	clock_t t1 = clock();
 
	float expected_fps   = 1.0f;
	float pixel_time     = ( t1 - output_buffer[launch_index].x ) * time_view_scale * expected_fps;
	output_buffer[launch_index] = make_float4( pixel_time );
#else
	if (code == RT_EXCEPTION_PROGRAM_ID_INVALID)
		output_buffer[launch_index] = make_float4(0.5f, 0.0f, 0.5f, 0.0f);
	else if (code == RT_EXCEPTION_TEXTURE_ID_INVALID)
		output_buffer[launch_index] = make_float4(0.5f, 0.0f, 0.0f, 0.0f);
	else if (code == RT_EXCEPTION_BUFFER_ID_INVALID)
		output_buffer[launch_index] = make_float4(0.0f, 1.0f, 1.0f, 0.0f);
	else if (code == RT_EXCEPTION_INDEX_OUT_OF_BOUNDS)
		output_buffer[launch_index] = make_float4(0.0f, 1.0f, 0.5f, 0.0f);
	else if (code == RT_EXCEPTION_STACK_OVERFLOW)
		output_buffer[launch_index] = make_float4(0.0f, 1.0f, 0.0f, 0.0f);
	else if (code == RT_EXCEPTION_BUFFER_INDEX_OUT_OF_BOUNDS)
		output_buffer[launch_index] = make_float4(0.0f, 0.5f, 0.5f, 0.0f);
	else if (code == RT_EXCEPTION_INVALID_RAY)
		output_buffer[launch_index] = make_float4(0.0f, 0.5f, 0.0f, 0.0f);
	else if (code == RT_EXCEPTION_INTERNAL_ERROR)
		output_buffer[launch_index] = make_float4(0.0f, 0.0f, 1.0f, 0.0f);
	else if (code == RT_EXCEPTION_USER)
		output_buffer[launch_index] = make_float4(0.0f, 0.0f, 0.5f, 0.0f);
	else {
		unsigned int error = code - RT_EXCEPTION_USER;
		output_buffer[launch_index] = make_float4((error >> 2) & 1u, (error >> 1) & 1u, error & 1u, 0.0f);
	}
#endif
}