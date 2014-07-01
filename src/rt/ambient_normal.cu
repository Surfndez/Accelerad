/*
 * Copyright (c) 2013-2014 Nathaniel Jones
 * Massachusetts Institute of Technology
 */

#include <optix.h>
#include <optixu/optixu_math_namespace.h>
#include <optixu/optixu_matrix_namespace.h>
#include "optix_shader_common.h"

using namespace optix;

#define  FRESNE(ci)	(expf(-5.85f*(ci)) - 0.00287989916f)
#define  FRESTHRESH	0.017999f	/* minimum specularity for approx. */

/* Context variables */
rtDeclareVariable(unsigned int, radiance_ray_type, , );
rtDeclareVariable(rtObject,     top_object, , );
#ifndef OLDAMB
rtDeclareVariable(unsigned int, shadow_ray_type, , );
rtDeclareVariable(rtObject,     top_shadower, , );
#endif /* OLDAMB */

rtDeclareVariable(float3,       CIE_rgbf, , ); /* This is the value [ CIE_rf, CIE_gf, CIE_bf ] from color.h */

rtDeclareVariable(float,        specthresh, , ); /* This is the minimum fraction of reflection or transmission, under which no specular sampling is performed */
rtDeclareVariable(float,        specjitter, , );

rtDeclareVariable(float3,       ambval, , ); /* This is the final value used in place of an indirect light calculation */
rtDeclareVariable(int,          ambvwt, , ); /* As new indirect irradiances are computed, they will modify the default ambient value in a moving average, with the specified weight assigned to the initial value given on the command and all other weights set to 1 */
rtDeclareVariable(int,          ambounce, , ); /* Ambient bounces (ab) */
//rtDeclareVariable(int,          ambres, , ); /* Ambient resolution (ar) */
rtDeclareVariable(float,        ambacc, , ); /* Ambient accuracy (aa). This value will approximately equal the error from indirect illuminance interpolation */
rtDeclareVariable(int,          ambdiv, , ); /* Ambient divisions (ad) */
rtDeclareVariable(int,          ambssamp, , ); /* Ambient super-samples (as) */
rtDeclareVariable(float,        maxarad, , ); /* maximum ambient radius */
rtDeclareVariable(float,        minarad, , ); /* minimum ambient radius */
rtDeclareVariable(float,        avsum, , ); /* computed ambient value sum (log) */
rtDeclareVariable(unsigned int, navsum, , ); /* number of values in avsum */

rtDeclareVariable(float,        minweight, , ); /* minimum ray weight (lw) */
rtDeclareVariable(int,          maxdepth, , ); /* maximum recursion depth (lr) */

/* Material variables */
rtDeclareVariable(unsigned int, type, , ); /* The material type representing "plastic", "metal", or "trans" */
rtDeclareVariable(float3,       color, , ); /* The material color given by the rad file "plastic", "metal", or "trans" object */
rtDeclareVariable(float,        spec, , ); /* The material specularity given by the rad file "plastic", "metal", or "trans" object */
rtDeclareVariable(float,        rough, , ); /* The material roughness given by the rad file "plastic", "metal", or "trans" object */
rtDeclareVariable(float,        trans, , ) = 0.0f; /* The material transmissivity given by the rad file "trans" object */
rtDeclareVariable(float,        tspec, , ) = 0.0f; /* The material transmitted specular component given by the rad file "trans" object */

/* OptiX variables */
rtDeclareVariable(Ray, ray, rtCurrentRay, );
rtDeclareVariable(float, t_hit, rtIntersectionDistance, );
rtDeclareVariable(PerRayData_ambient_record, prd, rtPayload, );

/* Attributes */
rtDeclareVariable(float3, geometric_normal, attribute geometric_normal, );
rtDeclareVariable(float3, shading_normal, attribute shading_normal, );


static __device__ int check_overlap( const float3& normal, const float3& hit );
#ifndef OLDAMB
static __device__ int plugaleak( const AmbientRecord* record, const float3& anorm, const float3& normal, const float3& hit, float ang );
static __device__ int doambient( float3 *rcol, float3 *u, float3 *v, float2 *ra, float2 *pg, float2 *dg, int *crlp, const float3& normal, const float3& hit );
static __device__ int samp_hemi( AMBHEMI *hp, float3 *rcol, float wt, const float3& normal, const float3& hit );
static __device__ int ambsample( AMBHEMI *hp, const int& i, const int& j, const float3& normal, const float3& hit );
static __device__ float back_ambval( AMBHEMI *hp, const int& n1, const int& n2, const int& n3 );
static __device__ void comp_fftri( FFTRI *ftp, AMBHEMI *hp, const int& n0, const int& n1, const float3& hit );
static __device__ optix::Matrix<3,3> compose_matrix( const float3& va, const float3& vb );
static __device__ optix::Matrix<3,3> comp_hessian( FFTRI *ftp, const float3& normal );
static __device__ float3 comp_gradient( FFTRI *ftp, const float3& normal );
static __device__ void eigenvectors( float3 *u, float3 *v, float2 *ra, optix::Matrix<3,3> *hessian );
static __device__ void ambHessian( AMBHEMI *hp, float3 *u, float3 *v, float2 *ra, float2 *pg, const float3& normal, const float3& hit );
static __device__ void ambdirgrad( AMBHEMI *hp, float3 *u, float3 *v, float2 *dg, const float3& normal, const float3& hit );
static __device__ unsigned int ambcorral( AMBHEMI *hp, float3 *u, float3 *v, const float2& r, const float3& normal, const float3& hit );
#else /* OLDAMB */
static __device__ float doambient( float3 *rcol, float3 *pg, float3 *dg, const float3& normal, const float3& hit );
static __device__ __inline__ void inithemi( AMBHEMI  *hp, const float3& ac, const float3& normal );
static __device__ int divsample( AMBSAMP  *dp, AMBHEMI  *h, const float3& hit );
//static __device__ void comperrs( AMBSAMP *da, AMBHEMI *hp );
//static __device__ int ambcmp( const void *p1, const void *p2 );
#endif /* OLDAMB */
//static __device__ float2 multisamp2(float r);
//static __device__ __inline__ int ilhash(int3 d);
static __device__ __inline__ float bright( const float3& rgb );

RT_PROGRAM void any_hit_ambient_glass()
{
	rtIgnoreIntersection();
}

RT_PROGRAM void closest_hit_ambient()
{
	float3 world_shading_normal   = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, shading_normal ) );
	float3 world_geometric_normal = normalize( rtTransformNormal( RT_OBJECT_TO_WORLD, geometric_normal ) );

	/* check for back side */
	// if backvis is false, create a new ray starting from the hit point (i.e., ignore this hit)
	float3 ffnormal = faceforward( world_shading_normal, -ray.direction, world_geometric_normal );
	float3 hit_point = ray.origin + t_hit * ray.direction;

	// Check that this is not covered by parent
	if ( check_overlap( ffnormal, hit_point ) )
		return;

	/* compute weight */
	//float weight = 1.0f;
	//for (int i = prd.ambient_depth; i-- > 0; ) //TODO start at i-1?
	//	weight *= AVGREFL;
	//if (prd.weight < 0.1f * weight)	/* heuristic override */
	//	weight = 1.25f * prd.weight;
	float3 acol = make_float3( AVGREFL );
#ifndef OLDAMB
	float3 u = make_float3( 0.0f );
	float3 v = make_float3( 0.0f );
	float2 pg = make_float2( 0.0f );
	float2 dg = make_float2( 0.0f );
	float2 rad = make_float2( 0.0f );
	int corral;

	/* compute ambient */
	int i = doambient( &acol, &u, &v, &rad, &pg, &dg, &corral, ffnormal, hit_point );
	if ( i <= 0 || rad.x <= FTINY )	/* no Hessian or zero radius */
		return;
#else
	float3 pg = make_float3( 0.0f );
	float3 dg = make_float3( 0.0f );

	/* compute ambient */
	float rad = doambient( &acol, &pg, &dg, ffnormal, hit_point );
	if ( rad <= FTINY )
		return;
#endif

	acol *= 1.0f / AVGREFL;		/* undo assumed reflectance */

	//if (rn != r->ron)
	//	extambient(acol, &amb, r->rop, rn);	/* texture */

	// pass the color back up the tree
	prd.result.pos = hit_point;
	prd.result.val = acol;
#ifndef OLDAMB
	prd.result.gpos = pg;
	prd.result.gdir = dg;
	prd.result.rad = rad;
	prd.result.ndir = encodedir( ffnormal );
	prd.result.udir = encodedir( u );
	prd.result.corral = corral;
#else
	prd.result.dir = ffnormal;
	prd.result.gpos = pg;
	prd.result.gdir = dg;
	prd.result.rad = rad;
#endif
	//prd.result.lvl = lvl;
	//prd.result.weight = weight;
}

// based on sumambient from ambient.c
static __device__ int check_overlap( const float3& normal, const float3& hit )
{
	// Check that there is a parent
	if ( !prd.parent )
		return( 0 );

#ifndef OLDAMB
	/* Direction test using unperturbed normal */
	float3 w = decodedir( prd.parent->ndir );
	float d = dot( w, normal );
	if ( d <= 0.0f )		/* >= 90 degrees */
		return( 0 );

	float delta_r2 = 2.0f - 2.0f * d;	/* approx. radians^2 */
	const float minangle = 10.0f * M_PIf / 180.0f;
	float maxangle = minangle + ambacc;
					/* adjust maximum angle */
	//if (at->alist != NULL && (at->alist->lvl <= al) & (r->rweight < 0.6))
	//	maxangle = (maxangle - PI/2.)*pow(r->rweight,0.13) + PI/2.;
	if ( delta_r2 >= maxangle * maxangle )
		return( 0 );

	/* Modified ray behind test */
	float3 ck0 = hit - prd.parent->pos;
	d = dot( ck0, w );
	if ( d < -minarad * ambacc - 0.001f )
		return( 0 );
	d /= prd.parent->rad.x;
	float delta_t2 = d * d;
	if ( delta_t2 >= ambacc * ambacc )
		return( 0 );
	
	/* Elliptical radii test based on Hessian */
	float3 u = decodedir( prd.parent->udir );
	float3 v = cross( w, u );
	float uu, vv;
	d = (uu = dot( ck0, u )) / prd.parent->rad.x;
	delta_t2 += d * d;
	d = (vv = dot( ck0, v )) / prd.parent->rad.y;
	delta_t2 += d * d;
	if ( delta_t2 >= ambacc * ambacc )
		return( 0 );
	
	/* Test for potential light leak */
	if ( prd.parent->corral && plugaleak( prd.parent, w, normal, hit, atan2f( vv, uu ) ) )
		return( 0 );
	return( 1 );
#else /* OLDAMB */
	/* Ambient radius test. */
	float3 ck0 = prd.parent->pos - hit;
	float rad = prd.parent->rad;
	float e1 = optix::dot( ck0, ck0 ) / ( rad * rad );
	float acc = ambacc * ambacc * 1.21f;
	if ( e1 > acc )
		return( 0 );

	/* Direction test using closest normal. */
	float d = optix::dot( prd.parent->dir, normal );
	//if (rn != r->ron) {
	//	rn_dot = DOT(av->dir, rn);
	//	if (rn_dot > 1.0-FTINY)
	//		rn_dot = 1.0-FTINY;
	//	if (rn_dot >= d-FTINY) {
	//		d = rn_dot;
	//		rn_dot = -2.0;
	//	}
	//}
	float e2 = (1.0f - d) * prd.result.weight;
	return( e2 < 0.0f || e1 + e2 <= acc );
#endif /* OLDAMB */
}

#ifndef OLDAMB
/* Plug a potential leak where ambient cache value is occluded */
static __device__ int plugaleak( const AmbientRecord* record, const float3& anorm, const float3& normal, const float3& hit, float ang )
{
	const float cost70sq = 0.1169778f;	/* cos(70deg)^2 */
	float2 t;

	ang += 2.0f * M_PIf * (ang < 0);			/* check direction flags */
	if ( !(record->corral>>(int)(ang*(16.0f/M_PIf)) & 1) )
		return(0);
	/*
	 * Generate test ray, targeting 20 degrees above sample point plane
	 * along surface normal from cache position.  This should be high
	 * enough to miss local geometry we don't really care about.
	 */
	float3 vdif = record->pos - hit;
	float normdot = dot( anorm, normal );
	float ndotd = dot( vdif, normal );
	float nadotd = dot( vdif, anorm );
	float a = normdot * normdot - cost70sq;
	float b = 2.0f * ( normdot * ndotd - nadotd * cost70sq );
	float c = ndotd * ndotd - dot( vdif, vdif ) * cost70sq;
	if ( quadratic( &t, a, b, c ) != 2 )
		return(1);			/* should rarely happen */
	if ( t.y <= FTINY )
		return(0);			/* should fail behind test */

	float3 rdir = vdif + anorm * t.y;	/* further dist. > plane */
	Ray shadow_ray = make_Ray( ray.origin, normalize( rdir ), shadow_ray_type, RAY_START, length( rdir ) );
	PerRayData_shadow shadow_prd;
	shadow_prd.result = make_float3( 1.0f );
	rtTrace( top_shadower, shadow_ray, shadow_prd );
	return( dot( shadow_prd.result, shadow_prd.result ) == 1.0f );	/* check for occluder */
}

#define AI(h,i,j)	((i)*(h)->ns + (j))
#define ambsam(h,i,j)	(h)->sa[AI(h,i,j)]

static __device__ int doambient( float3 *rcol, float3 *u, float3 *v, float2 *ra, float2 *pg, float2 *dg, int *crlp, const float3& normal, const float3& hit )
{
	float wt = prd.result.weight;
	AMBHEMI hp;
	if ( !samp_hemi( &hp, rcol, wt, normal, hit ) )
		return(0);
	float	d, K;
	AMBSAMP	*ap;
	int	i;
					/* clear return values */
	if (u != NULL)
		*u = make_float3( 0.0f );
	if (v != NULL)
		*v = make_float3( 0.0f );
	if (ra != NULL)
		*ra = make_float2( 0.0f );
	if (pg != NULL)
		*pg = make_float2( 0.0f );
	if (dg != NULL)
		*dg = make_float2( 0.0f );
	if (crlp != NULL)
		*crlp = 0;
	//if (hp == NULL)			/* sampling falure? */
	//	return(0);

	if ((ra == NULL) & (pg == NULL) & (dg == NULL) || (hp.sampOK < 0) | (hp.ns < 4)) { /* Hessian not requested/possible */
		return(-1);		/* value-only return value */
	}
	if ((d = bright(*rcol)) > FTINY) {	/* normalize Y values */
		d = 0.99f * ( hp.ns * hp.ns ) / d;
		K = 0.01f;
	} else {			/* or fall back on geometric Hessian */
		K = 1.0f;
		pg = NULL;
		dg = NULL;
		crlp = NULL;
	}
	ap = hp.sa;			/* relative Y channel from here on... */
	for (i = hp.ns*hp.ns; i--; ap++)
		ap->v.y = bright( ap->v ) * d + K;

	//if (uv == NULL)			/* make sure we have axis pointers */
	//	uv = my_uv;
					/* compute radii & pos. gradient */
	ambHessian( &hp, u, v, ra, pg, normal, hit );

	if (dg != NULL)			/* compute direction gradient */
		ambdirgrad( &hp, u, v, dg, normal, hit );

	if (ra != NULL) {		/* scale/clamp radii */
		if (pg != NULL) {
			if ( ra->x * (d = fabsf( pg->x ) ) > 1.0f )
				ra->x = 1.0f / d;
			if ( ra->y * (d = fabsf( pg->y ) ) > 1.0f )
				ra->y = 1.0f / d;
			if ( ra->x > ra->y )
				ra->x = ra->y;
		}
		if ( ra->x < minarad ) {
			ra->x = minarad;
			if ( ra->y < minarad )
				ra->y = minarad;
		}
		*ra *= 1.0f / sqrtf( wt );
		if ( ra->y > 2.0f * ra->x )
			ra->y = 2.0f * ra->x;
		if ( ra->y > maxarad ) {
			ra->y = maxarad;
			if ( ra->x > maxarad )
				ra->x = maxarad;
		}
					/* flag encroached directions */
		if ( (wt >= 0.89f * AVGREFL) & (crlp != NULL) )
			*crlp = ambcorral( &hp, u, v, *ra * ambacc, normal, hit );
		if (pg != NULL) {	/* cap gradient if necessary */
			d = pg->x*pg->x * ra->x*ra->x + pg->y*pg->y * ra->y*ra->y;
			if ( d > 1.0f ) {
				d = 1.0f / sqrtf(d);
				*pg *= d;
			}
		}
	}
	//free(hp);			/* clean up and return */
	return(1);
}

/* sample indirect hemisphere, based on samp_hemi in ambcomp.c */
static __device__ int samp_hemi( AMBHEMI *hp, float3 *rcol, float wt, const float3& normal, const float3& hit )
{
	float	d;
	int	j;
					/* set number of divisions */
	if (ambacc <= FTINY && wt > (d = 0.8f * fmaxf(*rcol) * wt / (ambdiv*minweight))) //TODO second wt should be radiance ray weight
		wt = d;			/* avoid ray termination */
	int n = sqrtf(ambdiv * wt) + 0.5f;
	int i = 1 + 5 * (ambacc > FTINY);	/* minimum number of samples */
	if (n < i)
		n = i;
					/* allocate sampling array */
	//hp = (AMBHEMI *)malloc(sizeof(AMBHEMI) + sizeof(AMBSAMP)*(n*n - 1));
	//if (hp == NULL)
	//	error(SYSTEM, "out of memory in samp_hemi");
	hp->ns = n;
	hp->acol = make_float3( 0.0f );
	//memset(hp->sa, 0, sizeof(AMBSAMP)*n*n);
	hp->sampOK = 0;
					/* assign coefficient */
	hp->acoef = *rcol;
	d = 1.0f / (n*n);
	hp->acoef *= d;
					/* make tangent plane axes */
	hp->uy = make_float3( curand_uniform( prd.state ), curand_uniform( prd.state ), curand_uniform( prd.state ) ) - 0.5f;
	hp->uy = fmaxf( cross_direction( normal ) * 2.0f - 1.0f, hp->uy );
	hp->ux = cross( hp->uy, normal );
	hp->ux = normalize( hp->ux );
	hp->uy = cross( normal, hp->ux );
					/* sample divisions */
	for (i = hp->ns; i--; )
	    for (j = hp->ns; j--; )
			hp->sampOK += ambsample( hp, i, j, normal, hit );
	*rcol = hp->acol;
	if (!hp->sampOK) {		/* utter failure? */
		//free(hp);
		return( 0 );
	}
	if (hp->sampOK < hp->ns * hp->ns) {
		//hp.sampOK *= -1;	/* soft failure */
		return( 1 );
	}
	//n = ambssamp * wt + 0.5f;
	//if (n > 8) {			/* perform super-sampling? */
	//	ambsupersamp(hp, n);
	//	*rcol = hp->acol;
	//}
	return( 1 );			/* all is well */
}

static __device__ int ambsample( AMBHEMI *hp, const int& i, const int& j, const float3& normal, const float3& hit )
{
	AMBSAMP	*ap = &ambsam(hp,i,j);
	PerRayData_radiance new_prd;
	float b2;
					/* generate hemispherical sample */
					/* ambient coefficient for weight */
	if (ambacc > FTINY)
		b2 = AVGREFL; // Reusing this variable
	else
		b2 = fmaxf(hp->acoef);
	new_prd.weight = prd.result.weight * b2;
	if (new_prd.weight < minweight) //if (rayorigin(&ar, AMBIENT, r, ar.rcoef) < 0)
		return(0);
	//if (ambacc > FTINY) {
	//	rcoef *= h->acoef;
	//	rcoef *= 1.0f / AVGREFL; // This all seems unnecessary
	//}
	//hlist[0] = hp->rp->rno;
	//hlist[1] = j;
	//hlist[2] = i;
	//multisamp(spt, 2, urand(ilhash(hlist,3)+n));
	float2 spt = 0.1f + 0.8f * make_float2( curand_uniform( prd.state ), curand_uniform( prd.state ) );
	//if (!n) {			/* avoid border samples for n==0 */
	//	if ((spt.x < 0.1f) | (spt.x >= 0.9f))
	//		spt.x = 0.1f + 0.8f * curand_uniform( prd.state );
	//	if ((spt.y < 0.1f) | (spt.y >= 0.9f))
	//		spt.y = 0.1f + 0.8f * curand_uniform( prd.state );
	//}
	SDsquare2disk( spt, (j+spt.y) / hp->ns, (i+spt.x) / hp->ns );
	float zd = sqrtf( 1.0f - dot( spt, spt ) );
	float3 rdir = normalize( spt.x*hp->ux + spt.y*hp->uy + zd*normal );
	//dimlist[ndims++] = AI(hp,i,j) + 90171;

	new_prd.depth = prd.result.lvl + 1;//prd.depth + 1;
	new_prd.ambient_depth = prd.result.lvl + 1;//prd.ambient_depth + 1;
	//new_prd.seed = prd.seed;//lcg( prd.seed );
	new_prd.state = prd.state;
#ifdef FILL_GAPS
	new_prd.primary = 0;
#endif
#ifdef RAY_COUNT
	new_prd.ray_count = 1;
#endif
	Ray amb_ray = make_Ray( hit, rdir, radiance_ray_type, RAY_START, RAY_END );
	rtTrace(top_object, amb_ray, new_prd);
#ifdef RAY_COUNT
	prd.ray_count += new_prd.ray_count;
#endif

	//ndims--;
	if ( isnan( new_prd.result ) ) // TODO How does this happen?
		return(0);
	if ( new_prd.distance <= FTINY )
		return(0);		/* should never happen */
	new_prd.result *= hp->acoef;	/* apply coefficient */
	//if ( new_prd.distance * ap->d < 1.0f )		/* new/closer distance? */ //TODO where did this value come from?
		ap->d = 1.0f / new_prd.distance;
	//if (!n) {			/* record first vertex & value */
		//if (ar.rt > 10.0*thescene.cusize)
		//	ar.rt = 10.0*thescene.cusize;
		ap->p = hit + rdir * new_prd.distance;
		ap->v = new_prd.result; // only one AMBSAMP, otherwise would need +=
	//} else {			/* else update recorded value */
	//	hp->acol -= ap->v;
	//	zd = 1.0f / (float)(n+1);
	//	new_prd.result *= zd;
	//	zd *= (float)n;
	//	ap->v *= zd;
	//	ap->v += new_prd.result;
	//}
	hp->acol += ap->v;	/* add to our sum */
	return(1);
}

/* Return brightness of farthest ambient sample */
static __device__ float back_ambval( AMBHEMI *hp, const int& n1, const int& n2, const int& n3 )
{
	if (hp->sa[n1].d <= hp->sa[n2].d) { //TODO how to get these three sample points
		if (hp->sa[n1].d <= hp->sa[n3].d)
			return(hp->sa[n1].v.y);
		return(hp->sa[n3].v.y);
	}
	if (hp->sa[n2].d <= hp->sa[n3].d)
		return(hp->sa[n2].v.y);
	return(hp->sa[n3].v.y);
}

/* Compute vectors and coefficients for Hessian/gradient calcs */
static __device__ void comp_fftri( FFTRI *ftp, AMBHEMI *hp, const int& n0, const int& n1, const float3& hit )
{
	ftp->r_i = hp->sa[n0].p - hit;
	ftp->r_i1 = hp->sa[n1].p - hit;
	ftp->e_i = hp->sa[n1].p - hp->sa[n0].p;
	ftp->rcp = cross( ftp->r_i, ftp->r_i1 );
	const float rdot_cp = 1.0f / dot( ftp->rcp, ftp->rcp );
	const float dot_e = dot( ftp->e_i, ftp->e_i );
	const float dot_er = dot( ftp->e_i, ftp->r_i );
	const float rdot_r = 1.0f / dot( ftp->r_i, ftp->r_i );
	const float rdot_r1 = 1.0f / dot( ftp->r_i1, ftp->r_i1 );
	ftp->I1 = acosf( dot( ftp->r_i, ftp->r_i1 ) * sqrtf( rdot_r * rdot_r1 ) ) * sqrtf( rdot_cp );
	ftp->I2 = ( dot( ftp->e_i, ftp->r_i1 ) * rdot_r1 - dot_er * rdot_r + dot_e * ftp->I1 ) * 0.5f * rdot_cp;
	const float J2 =  ( 0.5f * ( rdot_r - rdot_r1 ) - dot_er * ftp->I2 ) / dot_e;
	ftp->rI2_eJ2 = ftp->I2 * ftp->r_i + J2 * ftp->e_i;
}

/* Compose 3x3 matrix from two vectors */
static __device__ optix::Matrix<3,3> compose_matrix( const float3& va, const float3& vb )
{
	optix::Matrix<3,3> mat;
	mat.setRow( 0, va * vb.x + vb * va.x );
	mat.setRow( 1, va * vb.y + vb * va.y );
	mat.setRow( 2, va * vb.z + vb * va.z );
	//mat += mat.transpose();
	return mat;
}

/* Compute partial 3x3 Hessian matrix for edge */
static __device__ optix::Matrix<3,3> comp_hessian( FFTRI *ftp, const float3& normal )
{
					/* compute intermediate coefficients */
	float d1 = 1.0f / dot( ftp->r_i, ftp->r_i );
	float d2 = 1.0f / dot( ftp->r_i1, ftp->r_i1 );
	float d3 = 1.0f / dot( ftp->e_i, ftp->e_i );
	float d4 = dot( ftp->e_i, ftp->r_i );
	const float I3 = ( dot( ftp->e_i, ftp->r_i1 ) * d2 * d2 - d4 * d1 * d1 + 3.0f / d3 * ftp->I2 ) / ( 4.0f * dot( ftp->rcp, ftp->rcp ) );
	const float J3 = 0.25f * d3 * ( d1 * d1 - d2 * d2 ) - d4 * d3 * I3;
	const float K3 = d3 * ( ftp->I2 - I3 / d1 - 2.0f * d4 * J3);
					/* intermediate matrices */
	const float3 ncp = cross( normal, ftp->e_i );
	const optix::Matrix<3,3> m1 = compose_matrix( ncp, ftp->rI2_eJ2 );
	const optix::Matrix<3,3> m2 = compose_matrix( ftp->r_i, ftp->r_i );
	const optix::Matrix<3,3> m3 = compose_matrix( ftp->e_i, ftp->e_i );
	const optix::Matrix<3,3> m4 = compose_matrix( ftp->r_i, ftp->e_i );
	d1 = dot( normal, ftp->rcp );
	d2 = -d1 * ftp->I2;
	d1 *= 2.0f;
					/* final matrix sum */
	optix::Matrix<3,3> hess = m1 + d1 * ( I3 * m2 + K3 * m3 + 2.0f * J3 * m4 );
	hess += d2 * Matrix<3,3>::identity();
	hess *= -M_1_PIf;
	return hess;
}

/* Compute partial displacement form factor gradient for edge */
static __device__ float3 comp_gradient( FFTRI *ftp, const float3& normal )
{
	const float f1 = 2.0f * dot( normal, ftp->rcp );
	const float3 ncp = cross( normal, ftp->e_i );
	return M_PI_2f * ( ftp->I1 * ncp + f1 * ftp->rI2_eJ2 );
}

/* Compute anisotropic radii and eigenvector directions */
static __device__ void eigenvectors( float3 *u, float3 *v, float2 *ra, optix::Matrix<3,3> *hessian )
{
					/* project Hessian to sample plane */
	float3 a = *hessian * *u;
	float3 b = *hessian * *v;
	float4 hess2 = make_float4( dot( *u, a ), dot( *u, b ), dot( *v, a ), dot( *v, b ) );
					/* compute eigenvalue(s) */
	float2 evalue;
	unsigned int i = quadratic( &evalue, 1.0f, -hess2.x - hess2.w, hess2.x * hess2.w - hess2.y * hess2.z );
	//if (i == 1u)			/* double-root (circle) */
	//	evalue.y = evalue.x;
	if (!i || ((evalue.x = fabsf(evalue.x)) <= FTINY*FTINY) | ((evalue.y = fabsf(evalue.y)) <= FTINY*FTINY) ) {
		*ra = make_float2( maxarad );
		return;
	}
	float slope1;
	if ( evalue.x > evalue.y ) {
		*ra = sqrtf( sqrtf ( 4.0f / evalue ) );
		slope1 = evalue.y;
	} else {
		*ra = make_float2( sqrtf( sqrtf ( 4.0f / evalue.y ) ), sqrtf( sqrtf ( 4.0f / evalue.x ) ) );
		slope1 = evalue.x;
	}
					/* compute unit eigenvectors */
	if ( fabsf( hess2.y ) <= FTINY )
		return;			/* uv OK as is */
	slope1 = ( slope1 - hess2.x ) / hess2.y;
	const float xmag1 = sqrtf( 1.0f / ( 1.0f + slope1 * slope1 ) );
	b = xmag1 * *u + slope1 * xmag1 * *v;
	a = slope1 * xmag1 * *u - xmag1 * *v;
	*u = a;
	*v = b;
}

static __device__ void ambHessian( AMBHEMI *hp, float3 *u, float3 *v, float2 *ra, float2 *pg, const float3& normal, const float3& hit )
{
	optix::Matrix<3,3> hessrow[5]; //array of Matrix<3,3> //TODO set size (ns - 1)
	float3 gradrow[5];
	optix::Matrix<3,3> hessian;
	float3 gradient = make_float3( 0.0f );
	hessian.setRow( 0, gradient ); // Set zero matrix
	hessian.setRow( 1, gradient );
	hessian.setRow( 2, gradient );
	FFTRI fftr;
	int i, j;
					/* be sure to assign unit vectors */
	*u = hp->ux;
	*v = hp->uy;
			/* clock-wise vertex traversal from sample POV */
	//if (ra != NULL) {		/* initialize Hessian row buffer */
	//	hessrow = (FVECT (*)[3])malloc(sizeof(FVECT)*3*(hp->ns-1)); //TODO set memory size
	//	if (hessrow == NULL)
	//		error(SYSTEM, memerrmsg);
	//	memset(hessian, 0, sizeof(hessian));
	//} else if (pg == NULL)		/* bogus call? */
	//	return;
	//if (pg != NULL) {		/* initialize form factor row buffer */
	//	gradrow = (FVECT *)malloc(sizeof(FVECT)*(hp->ns-1));
	//	if (gradrow == NULL)
	//		error(SYSTEM, memerrmsg);
	//	memset(gradient, 0, sizeof(gradient));
	//}
					/* compute first row of edges */
	for (j = 0; j < hp->ns-1; j++) {
		comp_fftri( &fftr, hp, AI(hp,0,j), AI(hp,0,j+1), hit );//TODO specify target points
		if (hessrow != NULL)
			hessrow[j] = comp_hessian( &fftr, normal );
		if (gradrow != NULL)
			gradrow[j] = comp_gradient( &fftr, normal );
	}
					/* sum each row of triangles */
	for (i = 0; i < hp->ns-1; i++) {
	    optix::Matrix<3,3> hesscol;	/* compute first vertical edge */
	    float3 gradcol;
	    comp_fftri( &fftr, hp, AI(hp,i,0), AI(hp,i+1,0), hit );
	    if (hessrow != NULL)
			hesscol = comp_hessian( &fftr, normal );
	    if (gradrow != NULL)
			gradcol = comp_gradient( &fftr, normal );
	    for (j = 0; j < hp->ns-1; j++) {
			optix::Matrix<3,3> hessdia;	/* compute triangle contributions */
			float3 graddia;
			float backg = back_ambval( hp, AI(hp,i,j), AI(hp,i,j+1), AI(hp,i+1,j) );
						/* diagonal (inner) edge */
			comp_fftri( &fftr, hp, AI(hp,i,j+1), AI(hp,i+1,j), hit );
			if (hessrow != NULL) {
				hessdia = comp_hessian( &fftr, normal );
				//hesscol = -hesscol;
				hessian += backg * ( hessrow[j] + hessdia - hesscol );
			}
			if (gradrow != NULL) {
				graddia = comp_gradient( &fftr, normal );
				//gradcol = -gradcol;
				gradient += backg * ( gradrow[j] + graddia - gradcol );
			}
						/* initialize edge in next row */
			comp_fftri( &fftr, hp, AI(hp,i+1,j+1), AI(hp,i+1,j), hit );
			if (hessrow != NULL)
				hessrow[j] = comp_hessian( &fftr, normal );
			if (gradrow != NULL)
				gradrow[j] = comp_gradient( &fftr, normal );
						/* new column edge & paired triangle */
			backg = back_ambval( hp, AI(hp,i+1,j+1), AI(hp,i+1,j), AI(hp,i,j+1) );
			comp_fftri( &fftr, hp, AI(hp,i,j+1), AI(hp,i+1,j+1), hit );
			if (hessrow != NULL) {
				hesscol = comp_hessian( &fftr, normal );
				//hessdia = -hessdia;
				hessian += backg * ( hessrow[j] - hessdia + hesscol );
				if ( i < hp->ns-2 )
					hessrow[j] *= -1.0f;
			}
			if (gradrow != NULL) {
				gradcol = comp_gradient( &fftr, normal );
				//graddia = -graddia;
				gradient += backg * ( gradrow[j] - graddia + gradcol );
				if ( i < hp->ns-2 )
					gradrow[j] = -gradrow[j];
			}
	    }
	}
					/* release row buffers */
	//if (hessrow != NULL) free(hessrow);
	//if (gradrow != NULL) free(gradrow);
	
	if (ra != NULL)			/* extract eigenvectors & radii */
		eigenvectors( u, v, ra, &hessian );
	if (pg != NULL) {		/* tangential position gradient */
		*pg = make_float2( dot( gradient, *u ), dot( gradient, *v ) );
	}
}

/* Compute direction gradient from a hemispherical sampling */
static __device__ void ambdirgrad( AMBHEMI *hp, float3 *u, float3 *v, float2 *dg, const float3& normal, const float3& hit )
{
	AMBSAMP	*ap;
	int	n;

	float2 dgsum = make_float2( 0.0f );	/* sum values times -tan(theta) */
	for (ap = hp->sa, n = hp->ns*hp->ns; n--; ap++) { //TODO store these guys
					/* use vector for azimuth + 90deg */
		float3 vd = ap->p - hit;
					/* brightness over cosine factor */
		float gfact = ap->v.y / dot( normal, vd );
					/* sine = proj_radius/vd_length */
		dgsum.x -= dot( *v, vd ) * gfact;
		dgsum.y += dot( *u, vd ) * gfact;
	}
	*dg = dgsum / (hp->ns*hp->ns);
}

/* Compute potential light leak direction flags for cache value */
static __device__ unsigned int ambcorral( AMBHEMI *hp, float3 *u, float3 *v, const float2& r, const float3& normal, const float3& hit )
{
	const float max_d = 1.0f / ( minarad * ambacc + 0.001f );
	const float ang_res = M_PI_2f / ( hp->ns - 1 );
	const float ang_step = ang_res / ( (int)( 16.0f / M_PIf * ang_res ) + ( 1 + FTINY ) );
	float avg_d = 0.0f;
	unsigned int flgs = 0u;
	int i, j;
					/* don't bother for a few samples */
	if ( hp->ns < 12 )
		return(0u);
					/* check distances overhead */
	for ( i = hp->ns * 3 / 4; i-- > hp->ns>>2; )
	    for ( j = hp->ns * 3 / 4; j-- > hp->ns>>2; )
			avg_d += ambsam(hp,i,j).d;
	avg_d *= 4.0f / ( hp->ns * hp->ns );
	if ( avg_d * r.x >= 1.0f )		/* ceiling too low for corral? */
		return(0u);
	if ( avg_d >= max_d )		/* insurance */
		return(0u);
					/* else circle around perimeter */
	for ( i = 0; i < hp->ns; i++ )
	    for ( j = 0; j < hp->ns; j += !i|(i==hp->ns-1) ? 1 : hp->ns-1 ) {
			AMBSAMP	*ap = &ambsam(hp,i,j);
			if ( ( ap->d <= FTINY ) | ( ap->d >= max_d ) )
				continue;	/* too far or too near */
			const float3 vec = ap->p - hit;
			const float uu = dot( vec, *u );
			const float vv = dot( vec, *v );
			if ( ( r.x*r.x*uu*uu + r.y*r.y*vv*vv ) * ap->d*ap->d <= uu*uu + vv*vv )
				continue;	/* occluder outside ellipse */
			const float ang = atan2f( vv, uu );	/* else set direction flags */
			for ( float a1 = ang - 0.5f * ang_res; a1 <= ang + 0.5f * ang_res; a1 += ang_step )
				flgs |= 1L<<(int)( 16.0f / M_PIf * ( a1 + 2.0f * M_PIf * ( a1 < 0.0f ) ) );
	    }
					/* add low-angle incident (< 20deg) */
	if ( fabsf( dot( ray.direction, normal ) ) <= 0.342f ) {
		const float uu = -dot( ray.direction, *u );
		const float vv = -dot( ray.direction, *v );
		if ( ( r.x*r.x*uu*uu + r.y*r.y*vv*vv ) > t_hit * t_hit ) {
			float ang = atan2f( vv, uu );
			ang += 2.0f * M_PIf * ( ang < 0.0f );
			ang *= 16.0f / M_PIf;
			if ( ( ang < 0.5f ) | ( ang >= 31.5f ) )
				flgs |= 0x80000001;
			else
				flgs |= 3L<<(int)( ang - 0.5f );
		}
	}
	return(flgs);
}
#else /* OLDAMB */
#define ROW_SIZE	32	/* Number of entries allowed per row of the ambient hemisphere. */

static __device__ float doambient( float3 *rcol, float3 *pg, float3 *dg, const float3& nrm, const float3& hit_point )
{
	float  b, d;
	AMBHEMI  hemi;
	AMBSAMP  *div;
	AMBSAMP  dnew;
	float3  acol;
	AMBSAMP  *dp;
	float  arad;
	int  divcnt;
	unsigned int  i, j;
					/* initialize hemisphere */
	inithemi(&hemi, *rcol, nrm);
	divcnt = hemi.nt * hemi.np;
					/* initialize */
	//if (pg != NULL)
	//*pg = make_float3( 0.0f );
	//if (dg != NULL)
	//*dg = make_float3( 0.0f );
	*rcol = make_float3( 0.0f );
	if (divcnt == 0)
		return(0.0f); //TODO does this change the value of rcol in the calling method?
					/* allocate super-samples */
	//if (hemi.ns > 0) {// || pg != NULL || dg != NULL) {
	//	div = (AMBSAMP *)malloc(divcnt*sizeof(AMBSAMP));
	//	//if (div == NULL) // This is 0
	//	//	error(SYSTEM, "out of memory in doambient");
	//} else
		div = NULL; // This is 0
					/* sample the divisions */
	arad = 0.0f;
	acol = make_float3( 0.0f );
	if ((dp = div) == NULL)
		dp = &dnew;
	divcnt = 0;

	/* Set-up from posgradient in ambcomp.c */
	float rprevrow[ROW_SIZE]; //rprevrow[hemi.np]; //TODO allow larger -ad
	float bprevrow[ROW_SIZE]; //bprevrow[hemi.np];
	float xdp = 0.0f;
	float ydp = 0.0f;

	/* Set-up from dirgradient in ambcomp.c */
	float xdd = 0.0f;
	float ydd = 0.0f;

	for (j = 0u; j < hemi.np; j++) {
		/* Set-up from posgradient in ambcomp.c */
		float mag0 = 0.0f;
		float mag1 = 0.0f;
		float lastsine = 0.0f;
		float rprev, bprev;

		/* Set-up from dirgradient in ambcomp.c */
		float mag = 0.0f;

		for (i = 0u; i < hemi.nt; i++) {
			dp->t = i; dp->p = j;
			dp->v = make_float3( 0.0f );
			dp->r = 0.0f;
			dp->n = 0;
			if (divsample(dp, &hemi, hit_point) < 0) {
				rprevrow[i] = rprev = dp->r; // Set values for posgradient to avoid NaN
				bprevrow[i] = bprev = bright(dp->v);
				if (div != NULL)
					dp++;
				continue;
			}
			arad += dp->r;
			divcnt++;
			if (div != NULL)
				dp++;
			else
				acol += dp->v;

			/* Processing from posgradient in ambcomp.c */
			b = bright(dp->v);
			if (i > 0u) {
				d = rprev;//dp[-hp->np].r;
				if ( dp->r > d ) d = dp->r;
				d *= lastsine * ( 1.0f - (float)i / hemi.nt ); /* sin(t)*cos(t)^2 */
				mag0 += d * ( b - bprev ); // bright(dp[-hp->np].v)
			}
			float nextsine = sqrtf( (float)(i+1) / hemi.nt );
			if (j > 0u) {
				d = rprevrow[i];//dp[-1].r;
				if ( dp->r > d ) d = dp->r;
				mag1 += d * ( nextsine - lastsine ) * ( b - bprevrow[i] ); // bright(dp[-1].v)
			//} else {
			//	d = dp[hp->np-1].r;
			//	if ( dp->r > d ) d = dp->r;
			//	mag1 += d * (nextsine - lastsine) * (b - bright(dp[hp->np-1].v));
			}
			lastsine = nextsine;
			rprevrow[i] = rprev = dp->r;
			bprevrow[i] = bprev = b;

			/* Processing from dirgradient in ambcomp.c */
			mag += b / sqrtf( hemi.nt / ( i + 0.5f ) - 1.0f );
		}

		/* Processing from posgradient in ambcomp.c */
		mag0 *= 2.0f * M_PIf / hemi.np;
		float phi = 2.0f * M_PIf * (float)j / hemi.np;
		float cosp = cosf(phi);
		float sinp = sinf(phi);
		xdp += mag0 * cosp - mag1 * sinp;
		ydp += mag0 * sinp + mag1 * cosp;

		/* Processing from dirgradient in ambcomp.c */
		phi = 2.0f * M_PIf * ( j + 0.5f ) / hemi.np + M_PIf * 0.5f;
		xdd += mag * cosf(phi);
		ydd += mag * sinf(phi);
	}
	if (!divcnt) {
		//if (div != NULL)
		//	free((void *)div);
		return(0.0f);		/* no samples taken */
	}
	//if (divcnt < hemi.nt*hemi.np) {
	//	//pg = dg = NULL;		/* incomplete sampling */
	//	hemi.ns = 0;
	//} else if (arad > FTINY && divcnt/arad < minarad) {
	//	hemi.ns = 0;		/* close enough */
	//} else if (hemi.ns > 0) {	/* else perform super-sampling? */
	//	comperrs(div, &hemi);			/* compute errors */
	//	//qsort(div, divcnt, sizeof(AMBSAMP), ambcmp);	/* sort divs */ TODO necessary?
	//					/* super-sample */
	//	for (i = hemi.ns; i > 0u; i--) {
	//		dnew = *div;
	//		if (divsample(&dnew, &hemi, hit_point) < 0) {
	//			dp++;
	//			continue;
	//		}
	//		dp = div;		/* reinsert */
	//		j = divcnt < i ? divcnt : i;
	//		while (--j > 0 && dnew.k < dp[1].k) {
	//			*dp = *(dp+1);
	//			dp++;
	//		}
	//		*dp = dnew;
	//	}
	//	//if (pg != NULL || dg != NULL)	/* restore order */
	//	//	qsort(div, divcnt, sizeof(AMBSAMP), ambnorm);
	//}
					/* compute returned values */
	//if (div != NULL) {
		//arad = 0.0f;		/* note: divcnt may be < nt*np */
		//for (i = hemi.nt*hemi.np, dp = div; i-- > 0u; dp++) {
		//	arad += dp->r;
		//	if (dp->n > 1) {
		//		b = 1.0f/dp->n;
		//		dp->v *= b;
		//		dp->r *= b;
		//		dp->n = 1;
		//	}
		//	acol += dp->v;
		//}
		b = bright(acol);
		if (b > FTINY) {
			b = 1.0f / b;	/* compute & normalize gradient(s) */
			//if (pg != NULL) {
				//posgradient(pg, div, &hemi);
				*pg = ( xdp * hemi.ux + ydp * hemi.uy ) * ( (hemi.nt * hemi.np) / M_PIf );
				*pg *= b;
			//}
			//if (dg != NULL) {
				//dirgradient(dg, div, &hemi);
				*dg = xdd * hemi.ux + ydd * hemi.uy;
				*dg *= b;
			//}
		}
		//free((void *)div);
	//}
	*rcol = acol;
	if (arad <= FTINY)
		arad = maxarad;
	else
		arad = (divcnt+hemi.ns)/arad;
	//if (pg != NULL) {		/* reduce radius if gradient large */
		d = dot( *pg, *pg );
		if ( d * arad * arad > 1.0f )
			arad = 1.0f / sqrtf(d);
	//}
	if (arad < minarad) {
		arad = minarad;
		if ( /*pg != NULL &&*/ d * arad * arad > 1.0f ) {	/* cap gradient */
			d = 1.0f / arad / sqrtf(d);
			*pg *= d;
		}
	}
	if ((arad /= sqrtf(prd.result.weight)) > maxarad) //TODO check that weight is correct
		arad = maxarad;
	return(arad);
}

/* initialize sampling hemisphere */
static __device__ __inline__ void inithemi( AMBHEMI  *hp, const float3& ac, const float3& nrm )
{
	float	d;
	int  i;
	float wt = prd.result.weight;
					/* set number of divisions */
	if (ambacc <= FTINY && wt > (d = 0.8f * fmaxf(ac) * wt / (ambdiv*minweight)))
		wt = d;			/* avoid ray termination */
	hp->nt = sqrtf(ambdiv * wt / M_PIf) + 0.5f;
	i = ambacc > FTINY ? 3 : 1;	/* minimum number of samples */
	if (hp->nt < i)
		hp->nt = i;
	hp->np = M_PIf * hp->nt + 0.5f;
					/* set number of super-samples */
	hp->ns = ambssamp * wt + 0.5f;
					/* assign coefficient */
	hp->acoef = ac;
	d = 1.0f/(hp->nt*hp->np);
	hp->acoef *= d;
					/* make axes */
	hp->uz = nrm;
	hp->uy = cross_direction( hp->uz );
	hp->ux = normalize( cross(hp->uy, hp->uz) );
	hp->uy = normalize( cross(hp->uz, hp->ux) );
}

/* sample a division */
static __device__ int divsample( AMBSAMP  *dp, AMBHEMI  *h, const float3& hit_point )
{
	PerRayData_radiance new_prd;
	//RAY  ar;
	//float3 rcoef; /* contribution coefficient w.r.t. parent */
	//int3  hlist;
	float2  spt;
	float  xd, yd, zd;
	float  b2;
	float  phi;
					/* ambient coefficient for weight */
	if (ambacc > FTINY)
		b2 = AVGREFL; // Reusing this variable
	else
		b2 = fmaxf(h->acoef);
	new_prd.weight = prd.result.weight * b2;
	if (new_prd.weight < minweight) //if (rayorigin(&ar, AMBIENT, r, ar.rcoef) < 0)
		return(-1);
	//if (ambacc > FTINY) {
	//	rcoef *= h->acoef;
	//	rcoef *= 1.0f / AVGREFL; // This all seems unnecessary
	//}
	//hlist = make_int3( prd.seed, dp->t, dp->p );
	//multisamp(spt, 2, urand(ilhash(hlist,3)+dp->n));//TODO implement
	//spt = multisamp2( frandom() );
	//int il = ilhash( hlist );
	//spt = make_float2( rnd( il ) );
	//spt = make_float2( rnd( prd.seed ) );
	spt = make_float2( curand_uniform( prd.state ), curand_uniform( prd.state ) );
	zd = sqrtf((dp->t + spt.x)/h->nt);
	phi = 2.0f*M_PIf * (dp->p + spt.y)/h->np;
	xd = cosf(phi) * zd;
	yd = sinf(phi) * zd;
	zd = sqrtf(1.0f - zd*zd);
	float3 rdir = normalize( xd*h->ux + yd*h->uy + zd*h->uz );
	//dimlist[ndims++] = dp->t*h->np + dp->p + 90171;

	new_prd.depth = prd.result.lvl + 1;//prd.depth + 1;
	new_prd.ambient_depth = prd.result.lvl + 1;//prd.ambient_depth + 1;
	//new_prd.seed = prd.seed;//lcg( prd.seed );
	new_prd.state = prd.state;
#ifdef FILL_GAPS
	new_prd.primary = 1;
#endif
#ifdef RAY_COUNT
	new_prd.ray_count = 1;
#endif
#ifdef HIT_COUNT
	new_prd.hit_count = 0;
#endif
	Ray amb_ray = make_Ray( hit_point, rdir, radiance_ray_type, RAY_START, RAY_END );
	rtTrace(top_object, amb_ray, new_prd);
#ifdef RAY_COUNT
	prd.result.ray_count += new_prd.ray_count;
#endif
#ifdef HIT_COUNT
	prd.result.hit_count += new_prd.hit_count;
#endif

	//ndims--;
	if ( isnan( new_prd.result ) ) // TODO How does this happen?
		return(-1);
	new_prd.result *= h->acoef;	/* apply coefficient */
	dp->v += new_prd.result;
					/* use rt to improve gradient calc */
	if (new_prd.distance > FTINY && new_prd.distance < RAY_END)
		dp->r += 1.0f/new_prd.distance; //TODO should this be sum of distances?

					/* (re)initialize error */
	if (dp->n++) {
		b2 = bright(dp->v)/dp->n - bright(new_prd.result);
		b2 = b2*b2 + dp->k*((dp->n-1)*(dp->n-1));
		dp->k = b2/(dp->n*dp->n);
	} else
		dp->k = 0.0f;
	return(0);
}

/* compute initial error estimates */
//static __device__ void comperrs( AMBSAMP *da, AMBHEMI *hp )
//{
//	float  b, b2;
//	int  i, j;
//	AMBSAMP  *dp;
//				/* sum differences from neighbors */
//	dp = da;
//	for (i = 0; i < hp->nt; i++)
//		for (j = 0; j < hp->np; j++) {
////#ifdef  DEBUG
////			if (dp->t != i || dp->p != j)
////				error(CONSISTENCY,
////					"division order in comperrs");
////#endif
//			b = bright(dp[0].v);
//			if (i > 0) {		/* from above */
//				b2 = bright(dp[-hp->np].v) - b;
//				b2 *= b2 * 0.25f;
//				dp[0].k += b2;
//				dp[-hp->np].k += b2;
//			}
//			if (j > 0) {		/* from behind */
//				b2 = bright(dp[-1].v) - b;
//				b2 *= b2 * 0.25f;
//				dp[0].k += b2;
//				dp[-1].k += b2;
//			} else {		/* around */
//				b2 = bright(dp[hp->np-1].v) - b;
//				b2 *= b2 * 0.25f;
//				dp[0].k += b2;
//				dp[hp->np-1].k += b2;
//			}
//			dp++;
//		}
//				/* divide by number of neighbors */
//	dp = da;
//	for (j = 0; j < hp->np; j++)		/* top row */
//		(dp++)->k *= 1.0f/3.0f;
//	if (hp->nt < 2)
//		return;
//	for (i = 1; i < hp->nt-1; i++)		/* central region */
//		for (j = 0; j < hp->np; j++)
//			(dp++)->k *= 0.25f;
//	for (j = 0; j < hp->np; j++)		/* bottom row */
//		(dp++)->k *= 1.0f/3.0f;
//}

/* decreasing order */
//static __device__ int ambcmp( const void *p1, const void *p2 )
//{
//	const AMBSAMP	*d1 = (const AMBSAMP *)p1;
//	const AMBSAMP	*d2 = (const AMBSAMP *)p2;
//
//	if (d1->k < d2->k)
//		return(1);
//	if (d1->k > d2->k)
//		return(-1);
//	return(0);
//}
#endif /* OLDAMB */

/* convert 1-dimensional sample to 2 dimensions, based on multisamp.c */
//static __device__ __inline__ float2 multisamp2(float r)	/* 1-dimensional sample [0,1) */
//{
//	int	j;
//	register int	k;
//	int2	ti;
//	float	s;
//
//	ti = make_int2( 0 );
//	j = 8;
//	while (j--) {
//		k = s = r*(1<<2);
//		r = s - k;
//		ti += ti + make_int2( ((k>>2) & 1), ((k>>1) & 1) );
//	}
//	ti += make_int2( frandom() );
//	ti *= 1.0f/256.0f;
//}

/* hash a set of integer values */
//static __device__ __inline__ int ilhash(int3 d)
//{
//	register int  hval;
//
//	hval = 0;
//	hval ^= d.x * 73771;
//	hval ^= d.y * 96289;
//	hval ^= d.z * 103699;
//	return(hval & 0x7fffffff);
//}

static __device__ __inline__ float bright( const float3& rgb )
{
	return dot( rgb, CIE_rgbf );
}
