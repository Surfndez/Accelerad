/*
 * Copyright (c) 2013-2014 Nathaniel Jones
 * Massachusetts Institute of Technology
 */

#include <optix_world.h>
#include "optix_shader_common.h"

using namespace optix;

/* Program variables */
rtDeclareVariable(unsigned int,  stride, , ) = 1u; /* Spacing between used threads in warp. */

/* Contex variables */
rtBuffer<PointDirection, 1>      cluster_buffer; /* input */
rtBuffer<AmbientRecord, 1>       ambient_record_buffer; /* output */
rtDeclareVariable(rtObject,      top_object, , );
rtDeclareVariable(unsigned int,  ambient_record_ray_type, , );
rtDeclareVariable(unsigned int,  level, , ) = 0u;

/* OptiX variables */
rtDeclareVariable(uint2, launch_index, rtLaunchIndex, );
rtDeclareVariable(uint2, launch_dim,   rtLaunchDim, );
//rtDeclareVariable(unsigned int, launch_index, rtLaunchIndex, );
//rtDeclareVariable(unsigned int, launch_dim,   rtLaunchDim, );

// Initialize the random state
RT_METHOD void init_state( PerRayData_ambient_record* prd )
{
	rand_state state;
	prd->state = &state;
	curand_init( launch_index.y + launch_dim.y * level, 0, 0, prd->state );
}

RT_PROGRAM void ambient_cloud_camera()
{
	// Check stride
	if ( launch_index.y % stride )
		return;
	const unsigned int index = launch_index.y / stride;

	PerRayData_ambient_record prd;
	init_state( &prd );
	prd.parent = NULL;
	prd.result.lvl = level;
	prd.result.weight = 1.0f;
	for ( int i = level; i--; )
		prd.result.weight *= AVGREFL; // Compute weight as in makeambient() from ambient.c
#ifndef OLDAMB
	prd.result.rad = make_float2( 0.0f );
	prd.result.udir = 0; // Initialize in case something goes wrong
#else
	prd.result.rad = 0.0f;
	prd.result.dir = make_float3( 0.0f ); // Initialize in case something goes wrong
#endif
#ifdef RAY_COUNT
	prd.result.ray_count = 0;
#endif
#ifdef HIT_COUNT
	prd.result.hit_count = 0;
#endif

	// Get the position and normal of the ambient record to be created
	PointDirection cluster = cluster_buffer[index];

	if ( dot( cluster.dir, cluster.dir ) > FTINY ) { // Check that this is a valid ray
		float3 ray_direction = -normalize( cluster.dir ); // Ray will face opposite the normal direction
		Ray ray = make_Ray(cluster.pos, ray_direction, ambient_record_ray_type, -RAY_START, RAY_START);
		rtTrace(top_object, ray, prd);
	}

	ambient_record_buffer[index] = prd.result;
}

RT_PROGRAM void exception()
{
	// Check stride
	if ( launch_index.y % stride )
		return;

	const unsigned int code = rtGetExceptionCode();
	rtPrintf( "Caught exception 0x%X at launch index %d\n", code, launch_index.y );
	const unsigned int index = launch_index.y / stride;
	ambient_record_buffer[index].lvl = level;
	ambient_record_buffer[index].val = exceptionToFloat3( code );
#ifndef OLDAMB
	ambient_record_buffer[index].rad = make_float2( -1.0f );
#else
	ambient_record_buffer[index].rad = -1.0f;
#endif
}
