/*
 * Copyright (c) 2013-2014 Nathaniel Jones
 * Massachusetts Institute of Technology
 */

#include <stdio.h>

#include "ray.h" // required by ambient.h
#include "ambient.h"

#include "optix_radiance.h"
#include "optix_common.h"


static void updateAmbientCache( const RTcontext context, const unsigned int level );
static void createAmbientSamplingCamera( const RTcontext context, const VIEW* view );
static void createGeometryInstanceAmbient( const RTcontext context, RTgeometryinstance* instance, const unsigned int ambinet_record_count );
static void createAmbientAcceleration( const RTcontext context, const RTgeometryinstance instance );
static unsigned int populateAmbientRecords( const RTcontext context, const int level );
static unsigned int gatherAmbientRecords( AMBTREE* at, AmbientRecord** records, const int level );
static int saveAmbientRecords( AmbientRecord* record );

/* from rpict.c */
extern double  dstrpix;			/* square pixel distribution */

/* from ambient.c */
extern AMBTREE	atrunk;		/* our ambient trunk node */

extern double  avsum;		/* computed ambient value sum (log) */
extern unsigned int  navsum;	/* number of values in avsum */
extern unsigned int  nambvals;	/* total number of indirect values */

extern void avsave(AMBVAL *av);

/* Handles to objects used repeatedly in iterative irradiance cache builds */
static RTbuffer ambient_record_input_buffer;
static RTgeometry ambient_record_geometry;
static RTacceleration ambient_record_acceleration;

/* Allow faster irradiance cache creation by leaving some amount of threads unused.
	For 1D launch:
		Quadro K4000: Optimal is 4
		Tesla K40c: Optimal is 16
	For 2D (1xN) launch:
		Optimal is 2
*/
const unsigned int thread_stride = 2u;

#ifdef RAY_COUNT
static unsigned long ray_total = 0uL;
#endif
#ifdef HIT_COUNT
static unsigned long hit_total = 0uL;
#endif


void setupAmbientCache( const RTcontext context, const unsigned int level )
{
	/* Primary RTAPI objects */
	RTgeometryinstance  ambient_records;

	unsigned int ambient_record_count;

	ambient_record_count = populateAmbientRecords( context, level );
	createGeometryInstanceAmbient( context, &ambient_records, ambient_record_count );
	createAmbientAcceleration( context, ambient_records );
}

static void updateAmbientCache( const RTcontext context, const unsigned int level )
{
	unsigned int useful_record_count;
			
	// Populate ambinet records
	useful_record_count = populateAmbientRecords( context, level );
	RT_CHECK_ERROR( rtGeometrySetPrimitiveCount( ambient_record_geometry, useful_record_count ) );
	RT_CHECK_ERROR( rtAccelerationMarkDirty( ambient_record_acceleration ) );
}

static void createAmbientSamplingCamera( const RTcontext context, const VIEW* view )
{
	RTprogram  ray_gen_program;
	RTprogram  exception_program;

	if ( view ) { // use camera to pick points
		/* Ray generation program */
		ptxFile( path_to_ptx, "ambient_generator" );
		RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_camera", &ray_gen_program ) );
		applyProgramVariable1ui( context, ray_gen_program, "camera", view->type ); // -vt
		applyProgramVariable3f( context, ray_gen_program, "eye", view->vp[0], view->vp[1], view->vp[2] ); // -vp
		applyProgramVariable3f( context, ray_gen_program, "U", view->hvec[0], view->hvec[1], view->hvec[2] );
		applyProgramVariable3f( context, ray_gen_program, "V", view->vvec[0], view->vvec[1], view->vvec[2] );
		applyProgramVariable3f( context, ray_gen_program, "W", view->vdir[0], view->vdir[1], view->vdir[2] ); // -vd
		applyProgramVariable2f( context, ray_gen_program, "fov", view->horiz, view->vert ); // -vh, -vv
		applyProgramVariable2f( context, ray_gen_program, "shift", view->hoff, view->voff ); // -vs, -vl
		applyProgramVariable2f( context, ray_gen_program, "clip", view->vfore, view->vaft ); // -vo, -va
		//applyProgramVariable1f( context, ray_gen_program, "dstrpix", dstrpix ); // -pj

		/* Exception program */
		RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "exception", &exception_program ) );
	} else { // read input buffer for points
		/* Ray generation program */
		ptxFile( path_to_ptx, "ambient_cloud_generator" );
		RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_cloud_camera", &ray_gen_program ) );
		applyProgramVariable1ui( context, ray_gen_program, "stride", thread_stride );

		/* Exception program */
		RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "exception", &exception_program ) );
		applyProgramVariable1ui( context, exception_program, "stride", thread_stride );
	}
	RT_CHECK_ERROR( rtContextSetRayGenerationProgram( context, AMBIENT_ENTRY, ray_gen_program ) );
	RT_CHECK_ERROR( rtContextSetExceptionProgram( context, AMBIENT_ENTRY, exception_program ) );

	/* Define ray types */
	applyContextVariable1ui( context, "ambient_record_ray_type", AMBIENT_RECORD_RAY );
}

static void createGeometryInstanceAmbient( const RTcontext context, RTgeometryinstance* instance, const unsigned int ambinet_record_count )
{
	RTprogram  ambient_record_intersection_program;
	RTprogram  ambient_record_bounding_box_program;
	RTprogram  ambient_record_any_hit_program;
	RTprogram  ambient_record_miss_program;
	RTmaterial ambient_record_material;

	/* Create the geometry reference for OptiX. */
	RT_CHECK_ERROR( rtGeometryCreate( context, &ambient_record_geometry ) );
	RT_CHECK_ERROR( rtGeometrySetPrimitiveCount( ambient_record_geometry, ambinet_record_count ) );

	RT_CHECK_ERROR( rtMaterialCreate( context, &ambient_record_material ) );

	/* Define ray types */
	applyContextVariable1ui( context, "ambient_ray_type", AMBIENT_RAY );

	ptxFile( path_to_ptx, "ambient_records" );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_record_bounds", &ambient_record_intersection_program ) );
	RT_CHECK_ERROR( rtGeometrySetBoundingBoxProgram( ambient_record_geometry, ambient_record_intersection_program ) );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_record_intersect", &ambient_record_bounding_box_program ) );
	RT_CHECK_ERROR( rtGeometrySetIntersectionProgram( ambient_record_geometry, ambient_record_bounding_box_program ) );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_record_any_hit", &ambient_record_any_hit_program ) );
	RT_CHECK_ERROR( rtMaterialSetAnyHitProgram( ambient_record_material, AMBIENT_RAY, ambient_record_any_hit_program ) );

	/* Miss program */
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "ambient_miss", &ambient_record_miss_program ) );
	RT_CHECK_ERROR( rtContextSetMissProgram( context, AMBIENT_RAY, ambient_record_miss_program ) );
	// TODO miss program could handle makeambient()

	/* Create the geometry instance containing the ambient records. */
	RT_CHECK_ERROR( rtGeometryInstanceCreate( context, instance ) );
	RT_CHECK_ERROR( rtGeometryInstanceSetGeometry( *instance, ambient_record_geometry ) );
	RT_CHECK_ERROR( rtGeometryInstanceSetMaterialCount( *instance, 1 ) );

	/* Apply this material to the geometry instance. */
	RT_CHECK_ERROR( rtGeometryInstanceSetMaterial( *instance, 0, ambient_record_material ) );
}

static unsigned int populateAmbientRecords( const RTcontext context, const int level )
{
	//RTbuffer   ambient_record_input_buffer;
	void*      ambient_record_input_buffer_data;

	AmbientRecord* ambient_records, *ambient_records_ptr;
	unsigned int useful_record_count = 0u;

	/* Check that there are records */
	if ( nambvals ) {
		/* Allocate memory for temporary storage of ambient records. */
		ambient_records = (AmbientRecord*)malloc(sizeof(AmbientRecord) * nambvals);
		ambient_records_ptr = ambient_records;

		/* Get the ambient records from the octree structure. */
		useful_record_count = gatherAmbientRecords( &atrunk, &ambient_records_ptr, level );
		fprintf(stderr, "Using %u of %u ambient records\n", useful_record_count, nambvals);
	}

	/* Create or resize the buffer of ambient records. */
	if ( ambient_record_input_buffer ) {
		RT_CHECK_ERROR( rtBufferSetSize1D( ambient_record_input_buffer, useful_record_count ) );
	} else {
		createCustomBuffer1D( context, RT_BUFFER_INPUT, sizeof(AmbientRecord), useful_record_count, &ambient_record_input_buffer );
		applyContextObject( context, "ambient_records", ambient_record_input_buffer );
	}

	if ( nambvals ) {
		/* Copy ambient records from temporary storage to buffer. */
		RT_CHECK_ERROR( rtBufferMap( ambient_record_input_buffer, &ambient_record_input_buffer_data ) );
		memcpy( ambient_record_input_buffer_data, ambient_records, sizeof(AmbientRecord) * useful_record_count );
		RT_CHECK_ERROR( rtBufferUnmap( ambient_record_input_buffer ) );

		/* Free the temporary storage. */
		free(ambient_records);
	}

	return useful_record_count;
}

static unsigned int gatherAmbientRecords( AMBTREE* at, AmbientRecord** records, const int level )
{
	AMBVAL* record;
	AMBTREE* child;

	unsigned int count, i;
	count = 0u;

	for (record = at->alist; record != NULL; record = record->next) {
		if ( record->lvl <= level ) {
			array2cuda3( (*records)->pos, record->pos );
			array2cuda3( (*records)->val, record->val );
#ifndef OLDAMB
			array2cuda2( (*records)->gpos, record->gpos );
			array2cuda2( (*records)->gdir, record->gdir );
			array2cuda2( (*records)->rad, record->rad );

			(*records)->ndir = record->ndir;
			(*records)->udir = record->udir;
			(*records)->corral = record->corral;
#else
			array2cuda3( (*records)->dir, record->dir );
			array2cuda3( (*records)->gpos, record->gpos );
			array2cuda3( (*records)->gdir, record->gdir );

			(*records)->rad = record->rad;
#endif
			(*records)->lvl = record->lvl;
			(*records)->weight = record->weight;

			(*records)++;
			count++;
		}
	}

	child = at->kid;

	for (i = 0u; i < 8u; i++) {
		if (child != NULL) {
			count += gatherAmbientRecords( child++, records, level );
		}
	}
	return(count);
}

static int saveAmbientRecords( AmbientRecord* record )
{
	AMBVAL amb;

	/* Check that an ambient record was created. */
#ifndef OLDAMB
	float rad = record->rad.x;
#else
	float rad = record->rad;
#endif
	if ( rad < FTINY ) {
#ifdef DEBUG_OPTIX
		if ( rad < -FTINY ) // Something bad happened
			printException( record->val, "ambient level", record->lvl );
#endif
		return(0);
	}

	cuda2array3( amb.pos, record->pos );
	cuda2array3( amb.val, record->val );
#ifndef OLDAMB
	cuda2array2( amb.gpos, record->gpos );
	cuda2array2( amb.gdir, record->gdir );
	cuda2array2( amb.rad, record->rad );

	amb.ndir = record->ndir;
	amb.udir = record->udir;
	amb.corral = record->corral;
#else
	cuda2array3( amb.dir, record->dir );
	cuda2array3( amb.gpos, record->gpos );
	cuda2array3( amb.gdir, record->gdir );

	amb.rad = record->rad;
#endif
	amb.lvl = record->lvl;
	amb.weight = record->weight;
#ifdef RAY_COUNT
	ray_total += record->ray_count;
#endif
#ifdef HIT_COUNT
	hit_total += record->hit_count;
#endif

	avsave(&amb);
	return(1);
}

static void createAmbientAcceleration( const RTcontext context, const RTgeometryinstance instance )
{
	RTgeometrygroup geometrygroup;
	//RTacceleration  ambient_record_acceleration;

	/* Create a geometry group to hold the geometry instance.  This will be used as the top level group. */
	RT_CHECK_ERROR( rtGeometryGroupCreate( context, &geometrygroup ) );
	RT_CHECK_ERROR( rtGeometryGroupSetChildCount( geometrygroup, 1 ) );
	RT_CHECK_ERROR( rtGeometryGroupSetChild( geometrygroup, 0, instance ) );

	/* Set the geometry group as the top level object. */
	applyContextObject( context, "top_ambient", geometrygroup );

	/* create acceleration object for group and specify some build hints*/
	RT_CHECK_ERROR( rtAccelerationCreate( context, &ambient_record_acceleration ) );
	RT_CHECK_ERROR( rtAccelerationSetBuilder( ambient_record_acceleration, "Bvh" ) );
	RT_CHECK_ERROR( rtAccelerationSetTraverser( ambient_record_acceleration, "Bvh" ) );
	//RT_CHECK_ERROR( rtAccelerationSetProperty( ambient_record_acceleration, "refit", "1" ) ); // For Bvh, MedianBvh, and Lbvh only
	//RT_CHECK_ERROR( rtAccelerationSetProperty( ambient_record_acceleration, "refine", "1" ) ); // For Bvh, MedianBvh, and Lbvh only
	RT_CHECK_ERROR( rtGeometryGroupSetAcceleration( geometrygroup, ambient_record_acceleration ) );

	/* mark acceleration as dirty */
	RT_CHECK_ERROR( rtAccelerationMarkDirty( ambient_record_acceleration ) );
}

#ifndef KMEANS_IC
void createAmbientRecords( const RTcontext context, const VIEW* view, const int width, const int height )
{
	RTvariable     level_var, avsum_var, navsum_var;
	RTbuffer       ambient_record_buffer;
	AmbientRecord* ambient_record_buffer_data;

	unsigned int scaled_width, scaled_height, generated_record_count, useful_record_count, level, i;

	scaled_width = width / optix_amb_scale;
	scaled_height = height / optix_amb_scale;
	generated_record_count = scaled_width * scaled_height * optix_amb_semgents;
	level = ambounce;

	createAmbientSamplingCamera( context, view );

	RT_CHECK_ERROR( rtContextDeclareVariable( context, "level", &level_var ) ); // Could be camera program variable

	/* Create buffer for retrieving ambient records. */
	createCustomBuffer3D( context, RT_BUFFER_OUTPUT, sizeof(AmbientRecord), scaled_width, scaled_height, optix_amb_semgents, &ambient_record_buffer );
	applyContextObject( context, "ambient_record_buffer", ambient_record_buffer );
	applyContextVariable1ui( context, "segments", optix_amb_semgents );

	RT_CHECK_ERROR( rtContextQueryVariable( context, "avsum", &avsum_var ) );
	RT_CHECK_ERROR( rtContextQueryVariable( context, "navsum", &navsum_var ) );

	/* Put any existing ambient records into GPU cache. There should be none. */
	setupAmbientCache( context, 0u ); // Do this now to avoid additional setup time later

	while ( level-- ) {
		RT_CHECK_ERROR( rtVariableSet1ui( level_var, level ) );

		//ambdone();

		/* Run */
		runKernel2D( context, AMBIENT_ENTRY, scaled_width, scaled_height );

		RT_CHECK_ERROR( rtBufferMap( ambient_record_buffer, (void**)&ambient_record_buffer_data ) );
		RT_CHECK_ERROR( rtBufferUnmap( ambient_record_buffer ) );

		/* Copy the results to allocated memory. */
		//TODO the buffer could go directoy to creating Bvh
		useful_record_count = 0u;
		for (i = 0u; i < generated_record_count; i++) {
			useful_record_count += saveAmbientRecords( &ambient_record_buffer_data[i] );
		}
		fprintf(stderr, "Retrieved %u ambient records from %u queries at level %u.\n\n", useful_record_count, generated_record_count, level);

		// Populate ambinet records
		updateAmbientCache( context, level );

		/* Update ambient average. */
		RT_CHECK_ERROR( rtVariableSet1f( avsum_var, avsum ) );
		RT_CHECK_ERROR( rtVariableSet1ui( navsum_var, navsum ) );
	}

}
#else /* KMEANS_IC */
#define length_squared(v)	(v.x*v.x)+(v.y*v.y)+(v.z*v.z)
#define is_nan(v)			(v.x!=v.x)||(v.y!=v.y)||(v.z!=v.z)

static void createPointCloudCamera( const RTcontext context, const VIEW* view );
#ifdef ITERATIVE_KMEANS_IC
static void createHemisphereSamplingCamera( const RTcontext context );
#endif
static void createKMeansClusters( const unsigned int seed_count, const unsigned int cluster_count, PointDirection* seed_buffer_data, PointDirection* cluster_buffer_data, const unsigned int level );
//static void sortKMeans( const unsigned int cluster_count, PointDirection* cluster_buffer_data );
//static int clusterComparator( const void* a, const void* b );

/* return an array of cluster centers of size [numClusters][numCoords] */
float** cuda_kmeans(float **objects,	/* in: [numObjs][numCoords] */
					int     numCoords,	/* no. features */
					int     numObjs,		/* no. objects */
					int     numClusters,	/* no. clusters */
					int     max_iterations,	/* maximum k-means iterations */
					float   threshold,	/* % objects change membership */
					float   weight,	/* relative weighting of position */
					int    *membership,	/* out: [numObjs] */
					float  *distance,	/* out: [numObjs] */
					int    *loop_iterations);

void createAmbientRecords( const RTcontext context, const VIEW* view, const int width, const int height )
{
	RTvariable     level_var, avsum_var, navsum_var;
	RTbuffer       seed_buffer, ambient_record_buffer;
	PointDirection* seed_buffer_data, *cluster_buffer_data;
	AmbientRecord* ambient_record_buffer_data;
#ifdef ITERATIVE_KMEANS_IC
	RTvariable     current_cluster_buffer;
	RTbuffer*      cluster_buffer;
#else
	RTbuffer       cluster_buffer;
#endif

	unsigned int grid_width, grid_height, seeds_per_thread, seed_count, record_count, level, i;
#ifdef ITERATIVE_KMEANS_IC
	unsigned int divisions_theta, divisions_phi;
	double weight;

	seeds_per_thread = 1u;
#else
	seeds_per_thread = optix_amb_seeds_per_thread;
#endif
#ifdef VIEWPORT_IC
	grid_width = width / optix_amb_scale;
	grid_height = height / optix_amb_scale;
#else
	grid_width = optix_amb_grid_size;
	grid_height = 2u * grid_width;
#endif
	seed_count = grid_width * grid_height * seeds_per_thread;

	createPointCloudCamera( context, view );
#ifdef ITERATIVE_KMEANS_IC
	createHemisphereSamplingCamera( context );
#endif
	createAmbientSamplingCamera( context, NULL ); // Use input from kmeans to sample points instead of camera

	/* Create buffer for retrieving potential seed points. */
	createCustomBuffer3D( context, RT_BUFFER_OUTPUT, sizeof(PointDirection), grid_width, grid_height, seeds_per_thread, &seed_buffer );
	applyContextObject( context, "seed_buffer", seed_buffer );
	applyContextVariable1ui( context, "seeds", seeds_per_thread );

	/* Create buffer for inputting seed point clusters. */
#ifdef ITERATIVE_KMEANS_IC
	cluster_buffer = (RTbuffer*) malloc(ambounce * sizeof(RTbuffer));
	for ( level = 0u; level < ambounce; level++ ) {
		createCustomBuffer1D( context, RT_BUFFER_INPUT, sizeof(PointDirection), cuda_kmeans_clusters, &cluster_buffer[level] );
	}
	RT_CHECK_ERROR( rtContextDeclareVariable( context, "cluster_buffer", &current_cluster_buffer ) );
	RT_CHECK_ERROR( rtVariableSetObject( current_cluster_buffer, cluster_buffer[0] ) );
#else
	createCustomBuffer1D( context, RT_BUFFER_INPUT, sizeof(PointDirection), cuda_kmeans_clusters, &cluster_buffer );
	applyContextObject( context, "cluster_buffer", cluster_buffer );
#endif

	/* Create buffer for retrieving ambient records. */
	createCustomBuffer1D( context, RT_BUFFER_OUTPUT, sizeof(AmbientRecord), cuda_kmeans_clusters, &ambient_record_buffer );
	applyContextObject( context, "ambient_record_buffer", ambient_record_buffer );

	/* Set additional variables used for ambient record generation */
	RT_CHECK_ERROR( rtContextDeclareVariable( context, "level", &level_var ) ); // Could be camera program variable
	RT_CHECK_ERROR( rtVariableSet1ui( level_var, 0u ) ); // Must set a value in order to define type of variable

	RT_CHECK_ERROR( rtContextQueryVariable( context, "avsum", &avsum_var ) );
	RT_CHECK_ERROR( rtContextQueryVariable( context, "navsum", &navsum_var ) );

	/* Put any existing ambient records into GPU cache. There should be none. */
	setupAmbientCache( context, 0u ); // Do this now to avoid additional setup time later

	/* Run the kernel to get the first set of seed points. */
	runKernel2D( context, POINT_CLOUD_ENTRY, grid_width, grid_height );

#ifdef ITERATIVE_KMEANS_IC
	for ( level = 0u; level < ambounce; level++ ) {
		if ( level ) {
			/* Adjust output buffer size */
			weight = 1.0; //TODO set by level?
			for ( i = level; i--; )
				weight *= AVGREFL; //  Compute weight as in makeambient() from ambient.c
			divisions_theta = sqrtf( ambdiv * weight / PI ) + 0.5;
			i = ambacc > FTINY ? 3u : 1u;	/* minimum number of samples */
			if ( divisions_theta < i )
				divisions_theta = i;
			divisions_phi = PI * divisions_theta + 0.5;
			seed_count = cuda_kmeans_clusters * divisions_theta * divisions_phi;
			RT_CHECK_ERROR( rtBufferSetSize3D( seed_buffer, cuda_kmeans_clusters, divisions_theta, divisions_phi ) );

			/* Run kernel to gerate more seed points from cluster centers */
			runKernel3D( context, HEMISPHERE_SAMPLING_ENTRY, cuda_kmeans_clusters, divisions_theta, divisions_phi ); // stride?
		}

		/* Retrieve potential seed points. */
		RT_CHECK_ERROR( rtBufferMap( seed_buffer, (void**)&seed_buffer_data ) );
		RT_CHECK_ERROR( rtBufferUnmap( seed_buffer ) );

		/* Group seed points into clusters and add clusters to buffer */
		RT_CHECK_ERROR( rtBufferMap( cluster_buffer[level], (void**)&cluster_buffer_data ) );
		createKMeansClusters( seed_count, cuda_kmeans_clusters, seed_buffer_data, cluster_buffer_data, level );
		//sortKMeans( cuda_kmeans_clusters, cluster_buffer_data );
		RT_CHECK_ERROR( rtBufferUnmap( cluster_buffer[level] ) );

		/* Set input buffer index for next iteration */
		RT_CHECK_ERROR( rtVariableSetObject( current_cluster_buffer, cluster_buffer[level] ) );
	}
#else
	/* Retrieve potential seed points. */
	RT_CHECK_ERROR( rtBufferMap( seed_buffer, (void**)&seed_buffer_data ) );
	RT_CHECK_ERROR( rtBufferUnmap( seed_buffer ) );

	/* Group seed points into clusters and add clusters to buffer */
	RT_CHECK_ERROR( rtBufferMap( cluster_buffer, (void**)&cluster_buffer_data ) );
	createKMeansClusters( seed_count, cuda_kmeans_clusters, seed_buffer_data, cluster_buffer_data, 0u );
	//sortKMeans( cuda_kmeans_clusters, cluster_buffer_data );
	RT_CHECK_ERROR( rtBufferUnmap( cluster_buffer ) );

	level = ambounce;
#endif

	while ( level-- ) {
		RT_CHECK_ERROR( rtVariableSet1ui( level_var, level ) );

		/* Run */
		//runKernel1D( context, AMBIENT_ENTRY, cuda_kmeans_clusters * thread_stride );
		runKernel2D( context, AMBIENT_ENTRY, 1u, cuda_kmeans_clusters * thread_stride );

		RT_CHECK_ERROR( rtBufferMap( ambient_record_buffer, (void**)&ambient_record_buffer_data ) );
		RT_CHECK_ERROR( rtBufferUnmap( ambient_record_buffer ) );

		/* Copy the results to allocated memory. */
		//TODO the buffer could go directoy to creating Bvh
		record_count = 0u;
		for (i = 0u; i < cuda_kmeans_clusters; i++) {
			record_count += saveAmbientRecords( &ambient_record_buffer_data[i] );
		}
#ifdef RAY_COUNT
		fprintf(stderr, "Ray count %u (%f per thread).\n", ray_total, (float)ray_total/cuda_kmeans_clusters);
		ray_total = 0;
#endif
#ifdef HIT_COUNT
		fprintf(stderr, "Hit count %u (%f per thread).\n", hit_total, (float)hit_total/cuda_kmeans_clusters);
		hit_total = 0;
#endif
		fprintf(stderr, "Retrieved %u ambient records from %u queries at level %u.\n\n", record_count, cuda_kmeans_clusters, level);

		/* Copy new ambient values into buffer for Bvh. */
		updateAmbientCache( context, level );

#ifdef ITERATIVE_KMEANS_IC
		if ( level )
			RT_CHECK_ERROR( rtVariableSetObject( current_cluster_buffer, cluster_buffer[level - 1] ) );
#endif

		/* Update averages */
		RT_CHECK_ERROR( rtVariableSet1f( avsum_var, avsum ) );
		RT_CHECK_ERROR( rtVariableSet1ui( navsum_var, navsum ) );
	}

#ifdef ITERATIVE_KMEANS_IC
	free(cluster_buffer);
#endif
}

static void createPointCloudCamera( const RTcontext context, const VIEW* view )
{
	RTprogram  ray_gen_program;
	RTprogram  exception_program;
	RTprogram  miss_program;

	/* Ray generation program */
	ptxFile( path_to_ptx, "point_cloud_generator" );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "point_cloud_camera", &ray_gen_program ) );
	applyProgramVariable3f( context, ray_gen_program, "eye", view->vp[0], view->vp[1], view->vp[2] ); // -vp
#ifdef VIEWPORT_IC
	applyProgramVariable1ui( context, ray_gen_program, "camera", view->type ); // -vt
	applyProgramVariable3f( context, ray_gen_program, "U", view->hvec[0], view->hvec[1], view->hvec[2] );
	applyProgramVariable3f( context, ray_gen_program, "V", view->vvec[0], view->vvec[1], view->vvec[2] );
	applyProgramVariable3f( context, ray_gen_program, "W", view->vdir[0], view->vdir[1], view->vdir[2] ); // -vd
	applyProgramVariable2f( context, ray_gen_program, "fov", view->horiz, view->vert ); // -vh, -vv
	applyProgramVariable2f( context, ray_gen_program, "shift", view->hoff, view->voff ); // -vs, -vl
	applyProgramVariable2f( context, ray_gen_program, "clip", view->vfore, view->vaft ); // -vo, -va
#endif
	applyProgramVariable1f( context, ray_gen_program, "dstrpix", dstrpix ); // -pj
	RT_CHECK_ERROR( rtContextSetRayGenerationProgram( context, POINT_CLOUD_ENTRY, ray_gen_program ) );

	/* Exception program */
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "exception", &exception_program ) );
	RT_CHECK_ERROR( rtContextSetExceptionProgram( context, POINT_CLOUD_ENTRY, exception_program ) );

	/* Define ray types */
	applyContextVariable1ui( context, "point_cloud_ray_type", POINT_CLOUD_RAY );

	/* Miss program */
	ptxFile( path_to_ptx, "point_cloud_normal" );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "point_cloud_miss", &miss_program ) );
	RT_CHECK_ERROR( rtContextSetMissProgram( context, POINT_CLOUD_RAY, miss_program ) );
}

#ifdef ITERATIVE_KMEANS_IC
static void createHemisphereSamplingCamera( RTcontext context )
{
	RTprogram  ray_gen_program;
	RTprogram  exception_program;

	/* Ray generation program */
	ptxFile( path_to_ptx, "hemisphere_generator" );
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "hemisphere_camera", &ray_gen_program ) );
	RT_CHECK_ERROR( rtContextSetRayGenerationProgram( context, HEMISPHERE_SAMPLING_ENTRY, ray_gen_program ) );

	/* Exception program */
	RT_CHECK_ERROR( rtProgramCreateFromPTXFile( context, path_to_ptx, "exception", &exception_program ) );
	RT_CHECK_ERROR( rtContextSetExceptionProgram( context, HEMISPHERE_SAMPLING_ENTRY, exception_program ) );
}
#endif

static void createKMeansClusters( const unsigned int seed_count, const unsigned int cluster_count, PointDirection* seed_buffer_data, PointDirection* cluster_buffer_data, const unsigned int level )
{
	clock_t kernel_start_clock, kernel_end_clock; // Timer in clock cycles for short jobs
	unsigned int good_seed_count, i, j;
	PointDirection **seeds, **clusters; // input and output for cuda_kmeans()
	int *membership, loops; // output from cuda_kmeans()
	float *distance, *min_distance; // output from cuda_kmeans()

	/* Eliminate bad seeds and copy addresses to new array */
	good_seed_count = 0u;
	seeds = (PointDirection**) malloc(seed_count * sizeof(PointDirection*));
	//TODO Is there any point in filtering out values that are not valid (length(seed_buffer_data[i].dir) == 0)?
	for ( i = 0u; i < seed_count; i++) {
		if ( length_squared( seed_buffer_data[i].dir ) < FTINY ) {
			if ( length_squared( seed_buffer_data[i].pos ) > FTINY )
				printException( seed_buffer_data[i].pos, "seed", i );
		} else if ( is_nan( seed_buffer_data[i].pos ) || is_nan( seed_buffer_data[i].dir ) )
			fprintf(stderr, "NaN in seed %u (%g, %g, %g) (%g, %g, %g)\n", i, seed_buffer_data[i].pos.x, seed_buffer_data[i].pos.y, seed_buffer_data[i].pos.z, seed_buffer_data[i].dir.x, seed_buffer_data[i].dir.y, seed_buffer_data[i].dir.z);
		else
			seeds[good_seed_count++] = &seed_buffer_data[i];
	}
	fprintf(stderr, "Retrieved %u of %u potential seeds at level %u.\n", good_seed_count, seed_count, level);

	/* Check that enough seeds were found */
	if ( good_seed_count <= cluster_count ) {
		for ( i = 0u; i < good_seed_count; i++ )
			cluster_buffer_data[i] = *seeds[i];
		for ( ; i < cluster_count; i++ )
			cluster_buffer_data[i].dir.x = cluster_buffer_data[i].dir.y = cluster_buffer_data[i].dir.z = 0.0f; // Don't use this value
		free(seeds);
		return;
	}

	/* Group the seeds into clusters with k-means */
	membership = (int*) malloc(good_seed_count * sizeof(int));
	distance = (float*) malloc(good_seed_count * sizeof(float));
	kernel_start_clock = clock();
	clusters = (PointDirection**)cuda_kmeans((float**)seeds, sizeof(PointDirection) / sizeof(float), good_seed_count, cluster_count, cuda_kmeans_iterations, cuda_kmeans_threshold, cuda_kmeans_error, membership, distance, &loops);
	kernel_end_clock = clock();
	fprintf(stderr, "Kmeans performed %u loop iterations in %u milliseconds.\n", loops, (kernel_end_clock - kernel_start_clock) * 1000 / CLOCKS_PER_SEC);

	/* Populate buffer of seed point clusters. */
	min_distance = (float*) malloc(cluster_count * sizeof(float));
	for ( i = 0u; i < cluster_count; i++ )
		min_distance[i] = FHUGE;
	for ( i = 0u; i < good_seed_count; i++ ) {
		j = membership[i];
		if ( distance[i] < min_distance[j] ) { // || length_squared( cluster_buffer_data[j].dir ) > FTINY ) {
			min_distance[j] = distance[i];
			cluster_buffer_data[j] = *(seeds[i]);
		}
#ifdef DEBUG_OPTIX
		else if ( min_distance[j] != min_distance[j] )
			fprintf(stderr, "NaN distance from seed %u to cluster %u\n", i, j);
#endif
	}
	j = 0u;
	for ( i = 0u; i < cluster_count; i++ ) {
		if (min_distance[i] == FHUGE) {
			j++;
			cluster_buffer_data[i].dir.x = cluster_buffer_data[i].dir.y = cluster_buffer_data[i].dir.z = 0.0f; // Don't use this value
		}
#ifdef DEBUG_OPTIX
		else if ( is_nan(cluster_buffer_data[i].pos) || is_nan(cluster_buffer_data[i].dir) )
			fprintf(stderr, "NaN in cluster %u (%g, %g, %g) (%g, %g, %g)\n", i, cluster_buffer_data[i].pos.x, cluster_buffer_data[i].pos.y, cluster_buffer_data[i].pos.z, cluster_buffer_data[i].dir.x, cluster_buffer_data[i].dir.y, cluster_buffer_data[i].dir.z);
		else if (length_squared( cluster_buffer_data[i].dir ) < FTINY)
			fprintf(stderr, "Zero direction in cluster %u (%g, %g, %g) (%g, %g, %g)\n", i, cluster_buffer_data[i].pos.x, cluster_buffer_data[i].pos.y, cluster_buffer_data[i].pos.z, cluster_buffer_data[i].dir.x, cluster_buffer_data[i].dir.y, cluster_buffer_data[i].dir.z);
#endif
	}
	fprintf(stderr, "Kmeans produced %u of %u clusters at level %u.\n\n", cluster_count - j, cluster_count, level);

	/* Free memory */
	free(min_distance);
	free(clusters[0]); // allocated inside cuda_kmeans()
	free(clusters);
	free(distance);
	free(membership);
	free(seeds);
}

//typedef struct {
//	PointDirection*	data;	/* pointer to data */
//	int	membership;			/* cluster id */
//}  CLUSTER;
//
//static void sortKMeans( const unsigned int cluster_count, PointDirection* cluster_buffer_data )
//{
//	clock_t start_clock, end_clock; // Timer in clock cycles for short jobs
//	clock_t kernel_start_clock, kernel_end_clock; // Timer in clock cycles for short jobs
//	PointDirection **clusters, **groups, *temp;
//	unsigned int group_count, i;
//	CLUSTER* sortable;
//
//	int *membership, loops; // output from cuda_kmeans()
//	float *distance, *min_distance; // output from cuda_kmeans()
//
//	group_count = cluster_count / 4u;
//
//	start_clock = clock();
//
//	/* Copy addresses to new array */
//	clusters = (PointDirection**) malloc(cluster_count * sizeof(PointDirection*));
//	for ( i = 0u; i < cluster_count; i++ )
//		clusters[i] = &cluster_buffer_data[i];
//
//	/* Group the seeds into clusters with k-means */
//	membership = (int*) malloc(cluster_count * sizeof(int));
//	distance = (float*) malloc(cluster_count * sizeof(float));
//	kernel_start_clock = clock();
//	groups = (PointDirection**)cuda_kmeans((float**)clusters, sizeof(PointDirection) / sizeof(float), cluster_count, group_count, cuda_kmeans_threshold, cuda_kmeans_error, membership, distance, &loops);
//	kernel_end_clock = clock();
//	fprintf(stderr, "Kmeans performed %u loop iterations in %u milliseconds.\n", loops, (kernel_end_clock - kernel_start_clock) * 1000 / CLOCKS_PER_SEC);
//
//	temp = (PointDirection*) malloc(cluster_count * sizeof(PointDirection));
//	sortable = (CLUSTER*) malloc(cluster_count * sizeof(CLUSTER));
//	for ( i = 0u; i < cluster_count; i++ ) {
//		sortable[i].data = clusters[i];
//		sortable[i].membership = membership[i];
//	}
//	qsort( sortable, cluster_count, sizeof(CLUSTER), clusterComparator );
//	for ( i = 0u; i < cluster_count; i++ ) {
//		//clusters[i] = sortable[i].data;
//		temp[i] = *sortable[i].data;
//	}
//	memcpy(cluster_buffer_data, temp, cluster_count * sizeof(PointDirection));
//
//	/* Free memory */
//	free(sortable);
//	free(temp);
//	free(groups[0]); // allocated inside cuda_kmeans()
//	free(groups);
//	free(distance);
//	free(membership);
//	free(clusters);
//
//	end_clock = clock();
//	fprintf(stderr, "Sorting took %u milliseconds.\n", (end_clock - start_clock) * 1000 / CLOCKS_PER_SEC);
//}
//
//static int clusterComparator( const void* a, const void* b )
//{
//	return( ( (CLUSTER*) a )->membership - ( (CLUSTER*) b )->membership );
//}
#endif /* KMEANS_IC */