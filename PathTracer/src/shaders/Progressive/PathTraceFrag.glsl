#version 330

out vec3 color;
in vec2 TexCoords;
uniform bool isCameraMoving;
uniform bool hideEmitters;
uniform vec3 randomVector;
uniform vec2 screenResolution;

uniform sampler2D accumTexture;
uniform samplerBuffer BVH;
uniform samplerBuffer triangleIndicesTex;
uniform samplerBuffer verticesTex;
uniform samplerBuffer normalsTexCoordsTex;

uniform samplerBuffer materialsTex;
uniform samplerBuffer lightsTex;
uniform sampler2DArray albedoTextures;
uniform sampler2DArray metallicTextures;
uniform sampler2DArray roughnessTextures;
uniform sampler2DArray normalTextures;

uniform int numOfLights;
uniform int maxDepth;

#define PI        3.14159265358979323
#define TWO_PI    6.28318530717958648
#define INFINITY  1000000.0
#define EPS 0.001

vec2 seed;

vec3 tempNormal;

struct Ray { vec3 origin; vec3 direction; };
struct Material { vec4 albedo; vec4 param; vec4 texIDs; };
struct Camera { vec3 up; vec3 right; vec3 forward; vec3 position; float fov; float focalDist; float aperture; };
struct Light { vec3 position; vec3 emission; vec3 u; vec3 v; vec3 radiusAreaType; };
struct LightSample { vec3 surfacePos; vec3 normal; vec3 emission; vec2 areaType; };
struct State { vec3 normal; vec3 ffnormal; vec3 fhp; vec3 brdfDir; float pdf; bool isEmitter; int depth; float hitDist; vec2 texCoord; vec3 bary; int triID; int matID; Material mat; bool specularBounce; };

uniform Camera camera;

//-----------------------------------------------------------------------
float rand()
//-----------------------------------------------------------------------
{
	seed -= vec2(randomVector.x * randomVector.y);
	return fract(sin(dot(seed, vec2(12.9898, 78.233))) * 43758.5453);
}

//-----------------------------------------------------------------------
float SphereIntersect(float rad, vec3 pos, Ray r)
//-----------------------------------------------------------------------
{
	vec3 op = pos - r.origin;
	float eps = 0.001;
	float b = dot(op, r.direction);
	float det = b * b - dot(op, op) + rad * rad;
	if (det < 0.0)
		return INFINITY;

	det = sqrt(det);
	float t1 = b - det;
	if (t1 > eps)
		return t1;

	float t2 = b + det;
	if (t2 > eps)
		return t2;

	return INFINITY;
}

//-----------------------------------------------------------------------
float RectIntersect(in vec3 pos, in vec3 u, in vec3 v, in vec3 normal, in vec4 plane, in Ray r)
//-----------------------------------------------------------------------
{
	vec3 n = vec3(plane);
	float dt = dot(r.direction, n);
	float t = (plane.w - dot(n, r.origin)) / dt;
	if (t > EPS)
	{
		vec3 p = r.origin + r.direction * t;
		vec3 vi = p - pos;
		float a1 = dot(u, vi);
		if (a1 >= 0 && a1 <= 1)
		{
			float a2 = dot(v, vi);
			if (a2 >= 0 && a2 <= 1)
				return t;
		}
	}

	return INFINITY;
}

//----------------------------------------------------------------
float IntersectRayAABB(vec3 minCorner, vec3 maxCorner, Ray r)
//----------------------------------------------------------------
{
	vec3 invdir = 1.0 / r.direction;

	vec3 f = (maxCorner - r.origin) * invdir;
	vec3 n = (minCorner - r.origin) * invdir;

	vec3 tmax = max(f, n);
	vec3 tmin = min(f, n);

	float t1 = min(tmax.x, min(tmax.y, tmax.z));
	float t0 = max(tmin.x, max(tmin.y, tmin.z));

	return (t1 >= t0) ? (t0 > 0.f ? t0 : t1) : -1.0;
}

//-------------------------------------------------------------------------------
vec3 BarycentricCoord(vec3 point, vec3 v0, vec3 v1, vec3 v2)
//-------------------------------------------------------------------------------
{
	vec3 ab = v1 - v0;
	vec3 ac = v2 - v0;
	vec3 ah = point - v0;

	float ab_ab = dot(ab, ab);
	float ab_ac = dot(ab, ac);
	float ac_ac = dot(ac, ac);
	float ab_ah = dot(ab, ah);
	float ac_ah = dot(ac, ah);

	float inv_denom = 1.0 / (ab_ab * ac_ac - ab_ac * ab_ac);

	float v = (ac_ac * ab_ah - ab_ac * ac_ah) * inv_denom;
	float w = (ab_ab * ac_ah - ab_ac * ab_ah) * inv_denom;
	float u = 1.0 - v - w;

	return vec3(u, v, w);
}

//-----------------------------------------------------------------------
float SceneIntersect(Ray r, inout State state, inout LightSample lightSample)
//-----------------------------------------------------------------------
{
	float t = INFINITY;
	float d;

	// Intersect Emitters
	for (int i = 0; i < numOfLights; i++)
	{
		// Fetch light Data
		vec3 position = texelFetch(lightsTex, i * 5 + 0).xyz;
		vec3 emission = texelFetch(lightsTex, i * 5 + 1).xyz;
		vec3 u = texelFetch(lightsTex, i * 5 + 2).xyz;
		vec3 v = texelFetch(lightsTex, i * 5 + 3).xyz;
		vec3 radiusAreaType = texelFetch(lightsTex, i * 5 + 4).xyz;

		if (radiusAreaType.z == 0) // Rectangular Area Light
		{
			vec3 normal = normalize(cross(u, v));
			if (dot(normal, r.direction) > 0) // Hide backfacing quad light
				continue;
			vec4 plane = vec4(normal, dot(normal, position));
			u *= 1.0f / dot(u, u);
			v *= 1.0f / dot(v, v);

			d = RectIntersect(position, u, v, normal, plane, r);
			if (d < 0)
				d = INFINITY;
			if (d < t)
			{
				t = d;
				lightSample = LightSample(position, normal, emission, radiusAreaType.yz);
				state.isEmitter = true;
			}
		}
		if (radiusAreaType.z == 1) // Spherical Area Light
		{
			d = SphereIntersect(radiusAreaType.x, position, r);
			if (d < 0)
				d = INFINITY;
			if (d < t)
			{
				t = d;
				lightSample = LightSample(position, vec3(0), emission, radiusAreaType.yz);
				state.isEmitter = true;
				lightSample.normal = -r.direction;
			}
		}
	}

	int stack[64];
	int ptr = 0;
	stack[ptr++] = -1;

	int idx = 0;
	float leftHit = 0.0;
	float rightHit = 0.0;

	while (idx > -1)
	{
		int n = idx;
		vec3 LRLeaf = texelFetch(BVH, n * 3 + 2).xyz;

		int leftIndex = int(LRLeaf.x);
		int rightIndex = int(LRLeaf.y);
		int isLeaf = int(LRLeaf.z);

		if (isLeaf == 1)
		{
			for (int i = 0; i <= rightIndex; i++) // Loop through indices
			{
				int index = leftIndex + i;
				vec4 triIndex = texelFetch(triangleIndicesTex, index).xyzw;

				vec3 v0 = texelFetch(verticesTex, int(triIndex.x)).xyz;
				vec3 v1 = texelFetch(verticesTex, int(triIndex.y)).xyz;
				vec3 v2 = texelFetch(verticesTex, int(triIndex.z)).xyz;

				vec3 e0 = v1 - v0;
				vec3 e1 = v2 - v0;
				vec3 pv = cross(r.direction, e1);
				float det = dot(e0, pv);

				vec3 tv = r.origin - v0.xyz;
				vec3 qv = cross(tv, e0);

				vec4 uvt;
				uvt.x = dot(tv, pv);
				uvt.y = dot(r.direction, qv);
				uvt.z = dot(e1, qv);
				uvt.xyz = uvt.xyz / det;
				uvt.w = 1.0 - uvt.x - uvt.y;

				if (all(greaterThanEqual(uvt, vec4(0.0))) && uvt.z < t)
				{
					t = uvt.z;
					state.isEmitter = false;
					state.triID = int(triIndex.w);
					state.fhp = r.origin + r.direction * t;
					state.hitDist = t;
					state.bary = BarycentricCoord(state.fhp, v0, v1, v2);
				}
			}
		}
		else
		{
			leftHit = IntersectRayAABB(texelFetch(BVH, leftIndex * 3 + 0).xyz, texelFetch(BVH, leftIndex * 3 + 1).xyz, r);
			rightHit = IntersectRayAABB(texelFetch(BVH, rightIndex * 3 + 0).xyz, texelFetch(BVH, rightIndex * 3 + 1).xyz, r);

			if (leftHit > 0.0 && rightHit > 0.0)
			{
				int deferred = -1;
				if (leftHit > rightHit)
				{
					idx = rightIndex;
					deferred = leftIndex;
				}
				else
				{
					idx = leftIndex;
					deferred = rightIndex;
				}

				stack[ptr++] = deferred;
				continue;
			}
			else if (leftHit > 0)
			{
				idx = leftIndex;
				continue;
			}
			else if (rightHit > 0)
			{
				idx = rightIndex;
				continue;
			}
		}
		idx = stack[--ptr];
	}

	return t;
}

//-----------------------------------------------------------------------
bool SceneIntersectShadow(Ray r, float maxDist)
//-----------------------------------------------------------------------
{
	int stack[64];
	int ptr = 0;
	stack[ptr++] = -1;

	int idx = 0;
	float leftHit = 0.0;
	float rightHit = 0.0;

	while (idx > -1)
	{
		int n = idx;
		vec3 LRLeaf = texelFetch(BVH, n * 3 + 2).xyz;

		int leftIndex = int(LRLeaf.x);
		int rightIndex = int(LRLeaf.y);
		int isLeaf = int(LRLeaf.z);

		if (isLeaf == 1)
		{
			for (int i = 0; i <= rightIndex; i++) // Loop through indices
			{
				int index = leftIndex + i;
				vec4 triIndex = texelFetch(triangleIndicesTex, index).xyzw;

				vec3 v0 = texelFetch(verticesTex, int(triIndex.x)).xyz;
				vec3 v1 = texelFetch(verticesTex, int(triIndex.y)).xyz;
				vec3 v2 = texelFetch(verticesTex, int(triIndex.z)).xyz;

				vec3 e0 = v1 - v0;
				vec3 e1 = v2 - v0;
				vec3 pv = cross(r.direction, e1);
				float det = dot(e0, pv);

				vec3 tv = r.origin - v0.xyz;
				vec3 qv = cross(tv, e0);

				vec4 uvt;
				uvt.x = dot(tv, pv);
				uvt.y = dot(r.direction, qv);
				uvt.z = dot(e1, qv);
				uvt.xyz = uvt.xyz / det;
				uvt.w = 1.0 - uvt.x - uvt.y;

				if (all(greaterThanEqual(uvt, vec4(0.0))) && uvt.z < maxDist)
					return true;
			}
		}
		else
		{
			leftHit = IntersectRayAABB(texelFetch(BVH, leftIndex * 3 + 0).xyz, texelFetch(BVH, leftIndex * 3 + 1).xyz, r);
			rightHit = IntersectRayAABB(texelFetch(BVH, rightIndex * 3 + 0).xyz, texelFetch(BVH, rightIndex * 3 + 1).xyz, r);

			if (leftHit > 0.0 && rightHit > 0.0)
			{
				int deferred = -1;
				if (leftHit > rightHit)
				{
					idx = rightIndex;
					deferred = leftIndex;
				}
				else
				{
					idx = leftIndex;
					deferred = rightIndex;
				}

				stack[ptr++] = deferred;
				continue;
			}
			else if (leftHit > 0)
			{
				idx = leftIndex;
				continue;
			}
			else if (rightHit > 0)
			{
				idx = rightIndex;
				continue;
			}
		}
		idx = stack[--ptr];
	}

	return false;
}

//-----------------------------------------------------------------------
vec3 CosineSampleHemisphere(float u1, float u2)
//-----------------------------------------------------------------------
{
	vec3 dir;
	float r = sqrt(u1);
	float phi = 2.0 * PI * u2;
	dir.x = r * cos(phi);
	dir.y = r * sin(phi);
	dir.z = sqrt(max(0.0, 1.0 - dir.x*dir.x - dir.y*dir.y));

	return dir;
}

//-----------------------------------------------------------------------
vec3 UniformSampleSphere(float u1, float u2)
//-----------------------------------------------------------------------
{
	float z = 1.0 - 2.0 * u1;
	float r = sqrt(max(0.f, 1.0 - z * z));
	float phi = 2.0 * PI * u2;
	float x = r * cos(phi);
	float y = r * sin(phi);

	return vec3(x, y, z);
}

//-----------------------------------------------------------------------
void GetNormalAndTexCoord(inout State state, inout Ray r)
//-----------------------------------------------------------------------
{
	int index = state.triID;

	vec3 n1 = texelFetch(normalsTexCoordsTex, index * 6 + 0).xyz;
	vec3 n2 = texelFetch(normalsTexCoordsTex, index * 6 + 1).xyz;
	vec3 n3 = texelFetch(normalsTexCoordsTex, index * 6 + 2).xyz;

	vec3 t1 = texelFetch(normalsTexCoordsTex, index * 6 + 3).xyz;
	vec3 t2 = texelFetch(normalsTexCoordsTex, index * 6 + 4).xyz;
	vec3 t3 = texelFetch(normalsTexCoordsTex, index * 6 + 5).xyz;

	state.matID = int(t1.z);
	state.texCoord = t1.xy * state.bary.x + t2.xy * state.bary.y + t3.xy * state.bary.z;

	vec3 normal = normalize(n1 * state.bary.x + n2 * state.bary.y + n3 * state.bary.z);
	state.normal = normal;
	state.ffnormal = dot(normal, r.direction) <= 0.0 ? normal : normal * -1.0;
}

//-----------------------------------------------------------------------
void GetMaterialsAndTextures(inout State state, in Ray r)
//-----------------------------------------------------------------------
{
	int index = state.matID;
	Material mat;

	mat.albedo = texelFetch(materialsTex, index * 3 + 0);
	mat.param   = texelFetch(materialsTex, index * 3 + 1);
	mat.texIDs = texelFetch(materialsTex, index * 3 + 2);

	vec2 texUV = state.texCoord;

	if (int(mat.texIDs.x) >= 0)
		mat.albedo.xyz *= pow(texture(albedoTextures, vec3(texUV, int(mat.texIDs.x))).xyz, vec3(2.2)).xyz;

	if (int(mat.texIDs.y) >= 0)
		mat.param.x = pow(texture(metallicTextures, vec3(texUV, int(mat.texIDs.y))).x, 2.2);

	if (int(mat.texIDs.z) >= 0)
		mat.param.y = pow(texture(roughnessTextures, vec3(texUV, int(mat.texIDs.z))).x, 2.2);

	if (int(mat.texIDs.w) >= 0)
		tempNormal = pow(texture(normalTextures, vec3(texUV, int(mat.texIDs.w))).xyz, vec3(2.2));

	state.mat = mat;
}


//----------------------------Lambert BRDF----------------------------------

//-----------------------------------------------------------------------
void LambertPdf(Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 n = state.normal;
	vec3 V = -ray.direction;
	vec3 L = state.brdfDir;

	float pdfDiff = abs(dot(L, n)) * (1.0 / PI);

	state.pdf = pdfDiff;
}

//-----------------------------------------------------------------------
void LambertSample(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 N = state.normal;
	vec3 V = -ray.direction;

	vec3 dir;

	float r1 = rand();
	float r2 = rand();

	vec3 UpVector = abs(N.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
	vec3 TangentX = normalize(cross(UpVector, N));
	vec3 TangentY = cross(N, TangentX);

	dir = CosineSampleHemisphere(r1, r2);
	dir = TangentX * dir.x + TangentY * dir.y + N * dir.z;

	state.brdfDir = dir;
}

//-----------------------------------------------------------------------
vec3 LambertEval(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 N = state.normal;
	vec3 V = -ray.direction;
	vec3 L = state.brdfDir;

	float NDotL = dot(N, L);
	float NDotV = dot(N, V);
	if (NDotL <= 0.0 || NDotV <= 0.0)
		return vec3(0.0);

	vec3 brdf_col = state.mat.albedo.xyz / PI;

	return brdf_col * clamp(dot(N, L), 0.0, 1.0);
}

//-------------------------End of Lambert BRDF-------------------------------

//----------------------------UE4 BRDF----------------------------------

//-----------------------------------------------------------------------
float SchlickFresnel(float u)
//-----------------------------------------------------------------------
{
	float m = clamp(1.0 - u, 0.0, 1.0);
	float m2 = m * m;
	return m2 * m2*m; // pow(m,5)
}

//-----------------------------------------------------------------------
float GTR2(float NDotH, float a)
//-----------------------------------------------------------------------
{
	float a2 = a * a;
	float t = 1.0 + (a2 - 1.0)*NDotH*NDotH;
	return a2 / (PI * t*t);
}

//-----------------------------------------------------------------------
float SmithG_GGX(float NDotv, float alphaG)
//-----------------------------------------------------------------------
{
	float a = alphaG * alphaG;
	float b = NDotv * NDotv;
	return 1.0 / (NDotv + sqrt(a + b - a * b));
}

//-----------------------------------------------------------------------
void UE4Pdf(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 n = state.normal;
	vec3 V = -ray.direction;
	vec3 L = state.brdfDir;

	float specularAlpha = max(0.001, state.mat.param.y);

	float diffuseRatio = 0.5 * (1.0 - state.mat.param.x);
	float specularRatio = 1.0 - diffuseRatio;

	vec3 halfVec = normalize(L + V);

	float cosTheta = abs(dot(halfVec, n));
	float pdfGTR2 = GTR2(cosTheta, specularAlpha) * cosTheta;

	// calculate diffuse and specular pdfs and mix ratio
	float pdfSpec = pdfGTR2 / (4.0 * abs(dot(L, halfVec)));
	float pdfDiff = abs(dot(L, n)) * (1.0 / PI);

	// weight pdfs according to ratios
	state.pdf = diffuseRatio * pdfDiff + specularRatio * pdfSpec;
}

//-----------------------------------------------------------------------
void UE4Sample(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 N = state.normal;
	vec3 V = -ray.direction;

	vec3 dir;

	float probability = rand();
	float diffuseRatio = 0.5 * (1.0 - state.mat.param.x);

	float r1 = rand();
	float r2 = rand();

	vec3 UpVector = abs(N.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
	vec3 TangentX = normalize(cross(UpVector, N));
	vec3 TangentY = cross(N, TangentX);

	if (probability < diffuseRatio) // sample diffuse
	{
		dir = CosineSampleHemisphere(r1, r2);
		dir = TangentX * dir.x + TangentY * dir.y + N * dir.z;
	}
	else
	{
		float a = max(0.001, state.mat.param.y);

		float phi = r1 * 2.0 * PI;

		float cosTheta = sqrt((1.0 - r2) / (1.0 + (a*a - 1.0) *r2));
		float sinTheta = sqrt(1.0 - (cosTheta * cosTheta));
		float sinPhi = sin(phi);
		float cosPhi = cos(phi);

		vec3 halfVec = vec3(sinTheta*cosPhi, sinTheta*sinPhi, cosTheta);
		halfVec = TangentX * halfVec.x + TangentY * halfVec.y + N * halfVec.z;

		dir = 2.0*dot(V, halfVec)*halfVec - V;

	}
	state.brdfDir = dir;
}

//-----------------------------------------------------------------------
vec3 UE4Eval(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	vec3 N = state.normal;
	vec3 V = -ray.direction;
	vec3 L = state.brdfDir;

	float NDotL = dot(N, L);
	float NDotV = dot(N, V);
	if (NDotL <= 0.0 || NDotV <= 0.0)
		return vec3(0.0);

	vec3 H = normalize(L + V);
	float NDotH = dot(N, H);
	float LDotH = dot(L, H);

	// specular	
	float specular = 0.5;
	vec3 specularCol = mix(vec3(1.0) * 0.08 * specular, state.mat.albedo.xyz, state.mat.param.x);
	float a = max(0.001, state.mat.param.y);
	float Ds = GTR2(NDotH, a);
	float FH = SchlickFresnel(LDotH);
	vec3 Fs = mix(specularCol, vec3(1.0), FH);
	float roughg = (state.mat.param.y*0.5 + 0.5);
	roughg = roughg * roughg;
	float Gs = SmithG_GGX(NDotL, roughg) * SmithG_GGX(NDotV, roughg);

	vec3 brdf_col = (state.mat.albedo.xyz / PI) * (1.0 - state.mat.param.x) + Gs * Fs*Ds;

	return brdf_col * clamp(dot(N, L), 0.0, 1.0);
}

//-------------------------END OF UE4 BRDF-------------------------------

//----------------------------Glass BSDF----------------------------------

//-----------------------------------------------------------------------
void GlassPdf(Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	state.pdf = 1.0;
}

//-----------------------------------------------------------------------
void GlassSample(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	float n1 = 1.0;
	float n2 = state.mat.param.z;
	float R0 = (n1 - n2) / (n1 + n2);
	R0 *= R0;
	float theta = dot(-ray.direction, state.ffnormal);
	float prob = R0 + (1 - R0) * SchlickFresnel(theta);

	//vec3 transmittance = vec3(1.0);
	//vec3 extinction = -log(vec3(0.1, 0.1, 0.908));
	//vec3 extinction = -log(vec3(0.905, 0.63, 0.3));
	
	float eta = dot(state.normal, state.ffnormal) > 0.0 ? (n1 / n2) : (n2 / n1);
	vec3 transDir = normalize(refract(ray.direction, state.ffnormal, eta));
	float cos2t = 1.0 - eta * eta * (1.0 - theta * theta);

	//if(dot(-ray.direction, state.normal) <= 0.0)
	//	transmittance = exp(-extinction * state.hitDist * 100.0);

	if (cos2t < 0.0 || rand() < prob) // Reflection
	{
		state.brdfDir = normalize(reflect(ray.direction, state.ffnormal));
	}
	else  // Transmission
	{
		state.brdfDir = transDir;
	}
	//state.mat.albedo.xyz = transmittance;
}

//-----------------------------------------------------------------------
vec3 GlassEval(in Ray ray, inout State state)
//-----------------------------------------------------------------------
{
	return state.mat.albedo.xyz;
}

//-------------------------End of Glass BSDF-------------------------------

//------------------------Direct Light Evaluation----------------------

//-----------------------------------------------------------------------
float powerHeuristic(float a, float b)
//-----------------------------------------------------------------------
{
	float t = a * a;
	return t / (b*b + t);
}

//-----------------------------------------------------------------------
void sampleSphereLight(in Light light, inout LightSample lightSample)
//-----------------------------------------------------------------------
{
	float r1 = rand();
	float r2 = rand();
	lightSample.surfacePos = light.position + UniformSampleSphere(r1, r2) * light.radiusAreaType.x;
	lightSample.normal = normalize(lightSample.surfacePos - light.position);
	lightSample.areaType = light.radiusAreaType.yz;
}

//-----------------------------------------------------------------------
void sampleQuadLight(in Light light, inout LightSample lightSample)
//-----------------------------------------------------------------------
{
	float r1 = rand();
	float r2 = rand();
	lightSample.surfacePos = light.position + light.u * r1 + light.v * r2;
	lightSample.normal = normalize(cross(light.u, light.v));
	lightSample.areaType = light.radiusAreaType.yz;
}

//-----------------------------------------------------------------------
void sampleLight(in Light light, inout LightSample lightSample)
//-----------------------------------------------------------------------
{
	if (int(light.radiusAreaType.z) == 0) // Quad Light
		sampleQuadLight(light, lightSample);
	else
		sampleSphereLight(light, lightSample);
}

//-----------------------------------------------------------------------
vec3 DirectLight(in Ray r, in State state)
//-----------------------------------------------------------------------
{
	vec3 L = vec3(0.0);
	LightSample lightSample;
	Light light;
	bool done = false;

	//Pick a light to sample
	int index = int(rand() * numOfLights);

	// Fetch light Data
	vec3 p = texelFetch(lightsTex, index * 5 + 0).xyz;
	vec3 e = texelFetch(lightsTex, index * 5 + 1).xyz;
	vec3 u = texelFetch(lightsTex, index * 5 + 2).xyz;
	vec3 v = texelFetch(lightsTex, index * 5 + 3).xyz;
	vec3 rad = texelFetch(lightsTex, index * 5 + 4).xyz;

	light = Light(p, e, u, v, rad);

	vec3 surfacePos = state.fhp + state.normal * EPS;
	vec3 surfaceNormal = state.normal;

	sampleLight(light, lightSample);

	//Scale emission by number of lights
	lightSample.emission = light.emission * numOfLights;

	vec3 lightDir = lightSample.surfacePos - surfacePos;
	float lightDist = length(lightDir);
	float lightDistSq = lightDist * lightDist;
	lightDir /= sqrt(lightDistSq);

	if (dot(lightDir, surfaceNormal) <= 0.0 || dot(lightDir, lightSample.normal) >= 0.0)
		return L;

	Ray shadowRay = Ray(surfacePos, lightDir);
	bool inShadow = SceneIntersectShadow(shadowRay, lightDist - EPS);

	if (!inShadow)
	{
		float NdotL = dot(lightSample.normal, -lightDir);
		float lightPdf = lightDistSq / (lightSample.areaType.x * NdotL);

		state.brdfDir = lightDir;

		UE4Pdf(r, state);
		vec3 f = UE4Eval(r, state);

		L = powerHeuristic(lightPdf, state.pdf) * f * lightSample.emission / max(0.001, lightPdf);
	}

	return L;
}

//-----------------------------------------------------------------------
vec3 EmitterSample(in Ray r, in LightSample lightSample, in State state)
//-----------------------------------------------------------------------
{
	vec3 Le;
	if (state.depth == 0 || state.specularBounce)
	{
		Le = lightSample.emission;
	}
	else
	{
		float cosTheta = dot(-r.direction, lightSample.normal);
		float lightPdf = (state.hitDist * state.hitDist) / (lightSample.areaType.x * clamp(cosTheta, 0.001, 1.0));
		Le = powerHeuristic(state.pdf, lightPdf) * lightSample.emission;
	}
	return Le;
}

//---------------------------End of Direct Light Evaluation---------------------------

//-----------------------------------------------------------------------
vec3 PathTrace(Ray r)
//-----------------------------------------------------------------------
{
	vec3 radiance = vec3(0.0);
	vec3 throughput = vec3(1.0);
	State state;
	LightSample lightSample;

	for (int depth = 0; depth < maxDepth; depth++)
	{
		state.depth = depth;
		float t = SceneIntersect(r, state, lightSample);

		if (t == INFINITY)
		{
			/*vec3 bg_up = normalize(vec3(0.0f, -1.0, -1.0));
			bg_up.y += 1.0;
			bg_up = normalize(bg_up);
			float t = max(dot(r.direction, bg_up),0.0);
			radiance += throughput * mix(vec3(1.0), vec3(0.3), t);*/
			//float a = 0.5 * r.direction.y + 1.0;
			//radiance += throughput * (1.0 - a * vec3(1.0) + a * vec3(0.5, 0.7, 1.0));
			break;
		}

		GetNormalAndTexCoord(state, r);
		GetMaterialsAndTextures(state, r);

		if (state.isEmitter)
		{
			radiance += EmitterSample(r, lightSample, state) * throughput;
			break;
		}

		if (state.mat.albedo.w == 0.0)
		{
			state.specularBounce = false;
			vec3 direct = DirectLight(r, state) * throughput;

			if (depth < maxDepth && numOfLights > 0)
				radiance += direct;

			UE4Sample(r, state);
			UE4Pdf(r, state);

			if (state.pdf <= 0.0)
				break;
			throughput *= UE4Eval(r, state) / max(state.pdf, 0.001);
		}
		else
		{
			state.specularBounce = true;
			GlassSample(r, state);
			GlassPdf(r, state);

			throughput *= GlassEval(r, state) / state.pdf;
		}

		r.direction = state.brdfDir;
		r.origin = state.fhp + r.direction * EPS;
	}

	return radiance;
}

void main(void)
{
	seed = gl_FragCoord.xy;

	float r1 = 2.0 * rand();
	float r2 = 2.0 * rand();

	vec2 jitter;

	jitter.x = r1 < 1.0 ? sqrt(r1) - 1.0 : 1.0 - sqrt(2.0 - r1);
	jitter.y = r2 < 1.0 ? sqrt(r2) - 1.0 : 1.0 - sqrt(2.0 - r2);
	jitter /= (screenResolution * 0.5);

	vec2 d = (2.0 * TexCoords - 1.0) + jitter;
	d.x *= screenResolution.x / screenResolution.y * tan(camera.fov / 2.0);
	d.y *= tan(camera.fov / 2.0);
	vec3 rayDir = normalize(d.x * camera.right + d.y * camera.up + camera.forward);

	Ray ray = Ray(camera.position, rayDir);

	vec3 accumColor = texture(accumTexture, TexCoords).xyz;

	if (isCameraMoving)
		accumColor = vec3(0);

	vec3 pixelColor = PathTrace(ray);

	color = pixelColor + accumColor;
}