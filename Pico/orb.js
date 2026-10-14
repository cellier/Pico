// A soft, opaque white inflatable sphere. Its ink face is curved with the
// membrane, and is driven by the very same expression clock as both Pico skins.
class PicoOrbRig {
 constructor(parent){
  this.group=new Group();this.group.name='White Balloon — matte inflatable sphere';parent.add(this.group);this.group.rotation.y=.32;
  this.axes={x:1.20,y:1.20,z:1.20};this.expression='attentive';this.eyeMeshes=[];this.eyeUniforms=[];this.eyePrimitives=[];this.defaultFace=true;
  const membrane=new MeshPhysicalMaterial({color:0xffffff,metalness:0,roughness:.72,clearcoat:.015,clearcoatRoughness:.80,ior:1.40,specularIntensity:.27,envMapIntensity:.45,emissive:0xe7f1ff,emissiveIntensity:.025,toneMapped:false});
  // A little sky bounce is visible in the white vinyl, especially underneath.
  // It comes from illumination; the underlying material remains pure white.
  membrane.onBeforeCompile=shader=>{shader.fragmentShader=shader.fragmentShader.replace('#include <opaque_fragment>',`
   outgoingLight=outgoingLight*.36+vec3(.59,.62,.66);
   float lowerMembrane=1.0-smoothstep(-.85,.15,normal.y);
   outgoingLight-=vec3(.06,.055,.045)*lowerMembrane;
   #include <opaque_fragment>`);};
  membrane.customProgramCacheKey=()=> 'pico-white-inflatable-v1';
  const geometry=new SphereGeometry(1,192,128),p=geometry.attributes.position;
  for(let i=0;i<p.count;i++){
   const x=p.getX(i)*this.axes.x,y=p.getY(i)*this.axes.y,z=p.getZ(i)*this.axes.z;
   // The source's seams are almost invisible: a few shallow tension wrinkles
   // live at the left edge and below the mouth, never across the face itself.
   let fold=0;
   if(z>.35){
    for(const [cx,cy,tilt,length,depth] of [[-.91,.39,-.15,.13,.0040],[-.95,.26,-.16,.12,.0045],[-.93,.13,-.12,.10,.0036],[.04,-.67,1.44,.11,.0025]]){
     const dx=x-cx,dy=y-cy,c=Math.cos(tilt),s=Math.sin(tilt),along=c*dx+s*dy,across=-s*dx+c*dy;
     fold+=depth*Math.exp(-Math.pow(along/length,4))*Math.exp(-Math.pow(across/.014,2));
    }
   }
   p.setXYZ(i,x,y,z-fold);
  }
  geometry.computeVertexNormals();this.body=new Mesh(geometry,membrane);this.body.name='Continuous pure-white inflated membrane';this.body.castShadow=true;this.body.receiveShadow=true;this.group.add(this.body);
  const vertex=`varying vec2 facePoint;void main(){facePoint=position.xy;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}`;
  const fragment=`
   varying vec2 facePoint;uniform vec2 center;uniform vec2 size;uniform float curve;uniform float openness;uniform float tilt;uniform float heart;uniform float heartScale;uniform float mouth;
   float roundBox(vec2 q,vec2 b,float r){vec2 d=abs(q)-b+r;return min(max(d.x,d.y),0.0)+length(max(d,0.0))-r;}
   float smoothUnion(float a,float b,float k){float h=clamp(.5+.5*(b-a)/k,0.0,1.0);return mix(b,a,h)-k*h*(1.0-h);}
   // Keep the same rigid heart proportions, with a softly rounded tip and
   // cleft. Smooth distance joins avoid derivative spikes at tiny eye sizes.
   float heartDistance(vec2 p){
    float scale=heartScale*1.28;vec2 h=(p-center)/scale+vec2(0.0,.0732233);
    vec2 diamond=mat2(.70710678,-.70710678,.70710678,.70710678)*h;
    float base=roundBox(diamond,vec2(.5),.10);
    float left=length(h-vec2(-.35355339,.35355339))-.5;
    float right=length(h-vec2(.35355339,.35355339))-.5;
    return smoothUnion(base,smoothUnion(left,right,.08),.04)*scale;
   }
   // Exact circular centerline with circular end caps. A smile stays one
   // constant-width arc instead of bending and stretching a filled capsule.
   float roundArc(vec2 q,float halfWidth,float sag,float stroke){
    float h=max(abs(sag),.001),w=max(halfWidth-stroke,.001),r=(w*w+h*h)/(2.0*h);
    q.y*=sign(sag);vec2 v=q-vec2(0.0,r);
    float angle=atan(abs(v.x),-v.y),endAngle=atan(w,r-h);
    float d=angle<=endAngle?abs(length(v)-r):length(q-vec2(q.x<0.0?-w:w,h));return d-stroke;
   }
   void main(){
    vec2 q=facePoint-center;float c=cos(tilt),s=sin(tilt);q=mat2(c,-s,s,c)*q;
    float distance;
    if(mouth>.5){distance=abs(curve)>.004?roundArc(q,size.x,curve,size.y):roundBox(q,size,min(size.x,size.y));}
    else{
     float eyeDistance=(length(q/size)-1.0)*min(size.x,size.y);
     distance=abs(curve)>.014?roundArc(q-vec2(0.0,curve),size.x,-curve,size.y):eyeDistance;
     // A rigid heart has its own isotropic coordinate system. It is never
     // stretched by the eye pose, eyelid openness or a shape interpolation.
     if(heart>.5){
      distance=heartDistance(facePoint);
     }
    }
    float aa=max(fwidth(distance),.0014);float alpha=1.0-smoothstep(-aa,aa,distance);
    if(heart>.5&&mouth<.5){
     // Four subpixel coverage samples keep the contour stable while moving.
     // An isotropic pixel footprint avoids widening diagonal edges unevenly.
     vec2 dx=dFdx(facePoint)*.25,dy=dFdy(facePoint)*.25;
     float edge=max(length(vec2(dFdx(distance),dFdy(distance)))*.45,.0002);
     vec4 samples=vec4(heartDistance(facePoint-dx-dy),heartDistance(facePoint+dx-dy),heartDistance(facePoint-dx+dy),heartDistance(facePoint+dx+dy));
     alpha=dot(vec4(1.0)-smoothstep(vec4(-edge),vec4(edge),samples),vec4(.25));
    }
    if(alpha<.005)discard;gl_FragColor=vec4(vec3(.047,.070,.113),alpha);
   }`;
  for(const side of [-1,1]){
   const uniforms={center:{value:new Vector2(side*.315,.419)},size:{value:new Vector2(.10455,.10313)},curve:{value:0},openness:{value:1},tilt:{value:0},heart:{value:0},heartScale:{value:.108},mouth:{value:0}};
   const material=new ShaderMaterial({uniforms,vertexShader:vertex,fragmentShader:fragment,transparent:true,depthWrite:false,toneMapped:false});
   const mesh=new Mesh(this.patch(.64,.65,side*.315,.40),material);mesh.name=side<0?'Flush navy left ink eye':'Flush navy right ink eye';mesh.castShadow=mesh.receiveShadow=false;this.group.add(mesh);this.eyeMeshes.push(mesh);this.eyeUniforms.push(uniforms);
  }
  this.mouthUniforms={center:{value:new Vector2(0,.012)},size:{value:new Vector2(.22,.056)},curve:{value:0},openness:{value:1},tilt:{value:0},heart:{value:0},heartScale:{value:.108},mouth:{value:1}};
  const mouthMaterial=new ShaderMaterial({uniforms:this.mouthUniforms,vertexShader:vertex,fragmentShader:fragment,transparent:true,depthWrite:false,toneMapped:false});
  this.mouth=new Mesh(this.patch(1.22,.72,0,-.025),mouthMaterial);this.mouth.name='Short rounded horizontal ink mouth';this.mouth.castShadow=this.mouth.receiveShadow=false;this.group.add(this.mouth);
  this.group.visible=false;this.update(0,new PicoEyeMotion());
 }
 surfaceZ(x,y){return this.axes.z*Math.sqrt(Math.max(.001,1-(x/this.axes.x)**2-(y/this.axes.y)**2));}
 patch(width,height,cx,cy){
  const g=new PlaneGeometry(width,height,32,20),p=g.attributes.position;
  for(let i=0;i<p.count;i++){const x=p.getX(i)+cx,y=p.getY(i)+cy;p.setXYZ(i,x,y,this.surfaceZ(x,y)+.0028);}
  g.computeVertexNormals();return g;
 }
 update(dt,motion,{reduced=false,pressed=false}={}){
  const t=motion.time,passive=['idle','completed','cancelled','needs_input','awaiting_approval'].includes(motion.state);
  // Passive waiting and hover used to inherit the shared asymmetric "curious"
  // pose forever. This skin uses a symmetric listening-style resting face.
  // A click can still answer affectionately while waiting, without changing
  // the underlying task or approval state; holding and active voice take priority.
  const gesture=!pressed&&passive&&motion.gesture&&t-motion.gesture.start<2.6?motion.gesture.kind:null;
  let expression=gesture||motion.expression;
  this.defaultFace=!pressed&&passive&&!gesture&&['relaxed','curious','sleepy','soft-close','attentive'].includes(expression);
  if(pressed||this.defaultFace)expression='attentive';
  this.expression=expression;this.sourceExpression=motion.expression;
  const hearts=['happy','love'].includes(expression);
  const blink=Math.min(motion.left.open,motion.right.open);
  const restGazeX=(motion.left.x+motion.right.x)*.30,restGazeY=(motion.left.y+motion.right.y)*.275;
  for(let i=0;i<2;i++){
   const u=this.eyeUniforms[i],side=i?1:-1;
   let rx=.10455,ry=.10313,curve=0,tilt=0;
   if(expression==='pondering'){ry=.083;}
   else if(expression==='focused'){rx=.108;ry=.064;}
   else if(expression==='engaged'){ry=.094+(!reduced?Math.sin(t*3.1)*.004:0);}
   else if(expression==='concerned'){rx=.102;ry=.085;}
   else if(expression==='wink'&&i===0){rx=.116;ry=.017;curve=.039;tilt=.025;}
   u.center.value.set(side*.315+restGazeX,.419+restGazeY);
   u.size.value.set(hearts?.108:rx,hearts?.108:ry*Math.max(.055,blink));u.curve.value=hearts?0:curve*Math.max(.055,blink);
   u.openness.value=hearts?1:blink;u.tilt.value=tilt;u.heart.value=hearts?1:0;u.heartScale.value=.108;
   this.eyePrimitives[i]=hearts?'heart':Math.abs(u.curve.value)>.014?'roundArc':'ellipse';
  }
  let width=.22,height=.056,curve=0,y=.012,tilt=0;
  switch(expression){
   case 'attentive':width=this.defaultFace ? .22 : .19;height=.056;y=.012;break;
   case 'pondering':width=.21;height=.043;tilt=-.055;break;
   case 'focused':width=.245;height=.040;break;
   case 'engaged':width=.23;height=.047+(!reduced?Math.sin(t*6.5)**2*.025:0);break;
   case 'happy':case 'love':width=.28;height=.032;curve=.080;y=-.025;break;
   case 'wink':width=.27;height=.046;tilt=.12;break;
   case 'curious':width=.22;height=.056;break;
   case 'concerned':width=.23;height=.044;tilt=-.065;y=.025;break;
   case 'sleepy':case 'soft-close':width=.225;height=.038;break;
  }
  const u=this.mouthUniforms;u.center.value.set(0,y);u.size.value.set(width,height);u.curve.value=curve;u.tilt.value=tilt;
 }
 stats(){return {expression:this.expression,sourceExpression:this.sourceExpression,defaultFace:this.defaultFace,visible:this.group.visible,axes:{...this.axes},bodyVertices:this.body.geometry.attributes.position.count,bodyTriangles:this.body.geometry.index.count/3,eyeCenters:this.eyeUniforms.map(u=>u.center.value.toArray()),eyeSizes:this.eyeUniforms.map(u=>u.size.value.toArray()),eyePrimitives:[...this.eyePrimitives],eyeHearts:this.eyeUniforms.map(u=>u.heart.value),heartScales:this.eyeUniforms.map(u=>u.heartScale.value),eyeOpenness:this.eyeUniforms.map(u=>u.openness.value),mouthSize:this.mouthUniforms.size.value.toArray(),mouthY:this.mouthUniforms.center.value.y,mouthPrimitive:Math.abs(this.mouthUniforms.curve.value)>.004?'roundArc':'capsule',mouthTilt:this.mouthUniforms.tilt.value,mouthCurve:this.mouthUniforms.curve.value};}
}
