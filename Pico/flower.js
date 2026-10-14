// Pink Blossom is a second, genuinely volumetric skin. It shares Pico's motion
// controller; switching its visibility never restarts voice, gestures or time.
class PicoFlowerRig {
 constructor(parent,renderer){
  this.group=new Group();this.group.name='Pink Blossom — inflated six-petal flower';parent.add(this.group);
  this.expression='relaxed';this.eyeGroups=[];this.eyeMeshes=[];
  this.petals=Array.from({length:6},(_,i)=>{const a=Math.PI/2+i*Math.PI/3;return [Math.cos(a)*.82,Math.sin(a)*.82];});
  // The balloon has its own bright photography tent. Classic Pico's studio
  // and original material settings stay completely unchanged.
  const tent=new Scene();tent.background=new Color(0x95808d);
  for(const [x,y,z,w,h,color] of [[-3.4,4,5,3.6,5,0xffffff],[4,2.8,4,3.4,4.5,0xffffff],[0,5,-2,5,2,0xffe7f2],[-4,-1,-3,2,5,0xffc1de]]){
   const card=new Mesh(new PlaneGeometry(w,h),new MeshBasicMaterial({color,side:DoubleSide}));card.material.color.multiplyScalar(2.6);card.position.set(x,y,z);card.lookAt(0,0,0);tent.add(card);
  }
  const pmrem=new PMREMGenerator(renderer);this.environment=pmrem.fromScene(tent,.025);pmrem.dispose();tent.traverse(o=>{o.geometry?.dispose();o.material?.dispose();});
  const pink=new MeshPhysicalMaterial({color:0xff79b0,emissive:0xff9fc8,emissiveIntensity:.10,metalness:0,roughness:.13,clearcoat:1,clearcoatRoughness:.07,ior:1.46,specularIntensity:1,envMap:this.environment.texture,envMapIntensity:1.2});
  // Grazing light gives the opaque membrane a translucent, candy-pink rim,
  // without refracting a black render target through the transparent desktop.
  pink.onBeforeCompile=shader=>{shader.fragmentShader=shader.fragmentShader.replace('#include <lights_fragment_end>','#include <lights_fragment_end>\n reflectedLight.directSpecular *= .24;').replace('#include <opaque_fragment>',`
   float membraneRim=pow(1.0-clamp(dot(normal,normalize(vViewPosition)),0.0,1.0),2.0);
   outgoingLight+=vec3(1.0,.51,.73)*(.42*membraneRim);
   #include <opaque_fragment>`);};
  pink.customProgramCacheKey=()=> 'pico-blossom-membrane-v1';
  this.body=this.add('Continuous inflated flower membrane',this.makeBody(),pink,this.group);
  const seamMaterial=new MeshPhysicalMaterial({color:0xffb7d3,metalness:0,roughness:.23,clearcoat:1,clearcoatRoughness:.13,envMapIntensity:.8});
  const outline=[];for(let i=0;i<192;i++){const a=i/192*Math.PI*2,r=this.radius(Math.cos(a),Math.sin(a),0);outline.push(new Vector3(r*Math.cos(a),r*Math.sin(a),-.009));}
  const seam=this.add('Fine perimeter weld',new TubeGeometry(new CatmullRomCurve3(outline,true),384,.006,6,true),seamMaterial,this.group);seam.userData.passThrough=true;
  const cocoa=new MeshPhysicalMaterial({color:0x210b13,metalness:0,roughness:.16,clearcoat:1,clearcoatRoughness:.08,ior:1.48,envMapIntensity:1.05});
  const rose=new MeshPhysicalMaterial({color:0xe62464,metalness:0,roughness:.23,clearcoat:.85,clearcoatRoughness:.16,envMapIntensity:.75});
  const socketMaterial=new MeshPhysicalMaterial({color:0xea508a,metalness:0,roughness:.32,clearcoat:.6,envMapIntensity:.65});
  const glintMaterial=new MeshBasicMaterial({color:0xfff8fa,toneMapped:false});
  const sphereGeometry=new SphereGeometry(1,40,24);
  for(const side of [-1,1]){
   const eye=new Group();eye.name=side<0?'Blossom left eye':'Blossom right eye';this.group.add(eye);
   const socket=this.add('Soft rose eye socket',sphereGeometry,socketMaterial,eye);socket.scale.set(.119,.128,.039);socket.position.z=-.023;
   const bead=this.add('Glossy cocoa bead eye',sphereGeometry,cocoa,eye);bead.scale.set(.101,.112,.069);
   const glint=this.add('Eye softbox catchlight',sphereGeometry,glintMaterial,bead);glint.scale.set(.17,.21,.035);glint.position.set(.36,.46,.81);glint.castShadow=false;
   const arcPoints=[];for(let j=0;j<=24;j++){const t=j/24*2-1;arcPoints.push(new Vector3(t*.105,.045*(1-t*t),.023));}
   const arc=this.add('Smiling closed eye',new TubeGeometry(new CatmullRomCurve3(arcPoints),32,.021,10,false),cocoa,eye);
   const heart=new Shape();heart.moveTo(0,-.105);heart.bezierCurveTo(-.035,-.065,-.14,.015,-.095,.073);heart.bezierCurveTo(-.055,.122,-.007,.081,0,.055);heart.bezierCurveTo(.015,.093,.065,.11,.097,.072);heart.bezierCurveTo(.143,.01,.047,-.071,0,-.105);
   const love=this.add('Affectionate heart eye',new ExtrudeGeometry(heart,{depth:.025,bevelEnabled:true,bevelSize:.014,bevelThickness:.014,bevelSegments:4,curveSegments:16,steps:1}),cocoa,eye);love.position.z=.019;
   this.eyeGroups.push({group:eye,socket,bead,arc,love,side});this.eyeMeshes.push(bead);
  }
  this.mouthGeometry=this.makeMouthGeometry();this.mouth=this.add('Moulded raspberry smile',this.mouthGeometry,rose,this.group);
  this.mouthCaps=[-1,1].map(side=>{const m=this.add('Rounded smile corner',sphereGeometry,rose,this.group);m.userData.side=side;return m;});
  const inner=new MeshPhysicalMaterial({color:0x780b35,metalness:0,roughness:.36,clearcoat:.45,envMapIntensity:.6});
  this.openMouth=this.add('Soft open speaking mouth',sphereGeometry,inner,this.group);this.openMouth.scale.set(.13,.045,.036);
  this.group.visible=false;this.update(0,new PicoEyeMotion());
 }
 add(name,geometry,material,parent){const m=new Mesh(geometry,material);m.name=name;m.castShadow=true;m.receiveShadow=true;parent.add(m);return m;}
 // Smooth union of a central pillow and six elliptical balloons. A single
 // closed surface gives real side/back volume and continuous petal junctions.
 field(x,y,z){
  let d=(Math.hypot(x/.65,y/.65,z/.46)-1)*.46;
  for(const [cx,cy] of this.petals){const next=(Math.hypot((x-cx)/.49,(y-cy)/.49,z/.43)-1)*.43,k=.12,h=Math.max(k-Math.abs(d-next),0)/k;d=Math.min(d,next)-h*h*k*.25;}
  return d;
 }
 radius(x,y,z){let lo=0,hi=1.6;for(let i=0;i<23;i++){const mid=(lo+hi)*.5;if(this.field(x*mid,y*mid,z*mid)>0)hi=mid;else lo=mid;}return (lo+hi)*.5;}
 surfaceZ(x,y){let lo=0,hi=.8;for(let i=0;i<18;i++){const z=(lo+hi)*.5;if(this.field(x,y,z)>0)hi=z;else lo=z;}return (lo+hi)*.5;}
 makeBody(){
  const segments=192,rings=80,vertices=[0,0,this.radius(0,0,1)],indices=[];
  for(let j=1;j<rings;j++){const phi=j/rings*Math.PI,s=Math.sin(phi),z=Math.cos(phi);for(let i=0;i<segments;i++){const a=i/segments*Math.PI*2,x=s*Math.cos(a),y=s*Math.sin(a),r=this.radius(x,y,z);vertices.push(x*r,y*r,z*r);}}
  const back=vertices.length/3;vertices.push(0,0,-this.radius(0,0,-1));
  for(let i=0;i<segments;i++)indices.push(0,1+i,1+(i+1)%segments);
  for(let j=0;j<rings-2;j++)for(let i=0;i<segments;i++){const a=1+j*segments+i,b=1+j*segments+(i+1)%segments,c=a+segments,d=b+segments;indices.push(a,c,b,b,c,d);}
  const last=1+(rings-2)*segments;for(let i=0;i<segments;i++)indices.push(last+i,back,last+(i+1)%segments);
  const g=new BufferGeometry();g.setAttribute('position',new Float32BufferAttribute(vertices,3));g.setIndex(indices);g.computeVertexNormals();return g;
 }
 makeMouthGeometry(){const segments=48,sides=12,g=new BufferGeometry(),idx=[];g.setAttribute('position',new Float32BufferAttribute(new Float32Array((segments+1)*(sides+1)*3),3));g.setAttribute('normal',new Float32BufferAttribute(new Float32Array((segments+1)*(sides+1)*3),3));for(let i=0;i<segments;i++)for(let j=0;j<sides;j++){const a=i*(sides+1)+j,b=a+sides+1;idx.push(a,a+1,b,b,a+1,b+1);}g.setIndex(idx);return g;}
 updateMouth(width,curve,y,radius,open){
  // The moulded smile changes only with expression. Speech animates the inner
  // mouth scale below, so unchanged frames can reuse the mesh and its bounds.
  const previous=this.mouthShape;
  if(!previous||previous.width!==width||previous.curve!==curve||previous.y!==y||previous.radius!==radius){
   const p=this.mouthGeometry.attributes.position,n=this.mouthGeometry.attributes.normal;
   for(let i=0;i<=48;i++){const t=i/24-1,x=t*width,cy=y+curve*t*t,z=this.surfaceZ(x,cy)+.023,dy=2*curve*t/width,inv=1/Math.hypot(1,dy),r=radius*(.87+.13*(1-t*t));
    for(let j=0;j<=12;j++){const angle=j/12*Math.PI*2,c=Math.cos(angle),s=Math.sin(angle),nx=-dy*inv*c,ny=inv*c,k=i*13+j;p.setXYZ(k,x+nx*r,cy+ny*r,z+s*r*.72);n.setXYZ(k,nx,ny,s/ .72);}
   }
   p.needsUpdate=true;n.needsUpdate=true;this.mouthGeometry.computeBoundingSphere();
   for(const cap of this.mouthCaps){const x=cap.userData.side*width,cy=y+curve;cap.position.set(x,cy,this.surfaceZ(x,cy)+.023);cap.scale.setScalar(radius*.87);cap.scale.z*=.72;}
   this.mouthShape={width,curve,y,radius,innerZ:this.surfaceZ(0,y+.035)+.010};
  }
  this.openMouth.visible=open>.015;this.openMouth.position.set(0,y+.035,this.mouthShape.innerZ);this.openMouth.scale.set(width*.59,Math.max(.004,open),.039);
 }
 update(dt,motion,{reduced=false}={}){
  this.expression=motion.expression;const t=motion.time;
  for(let i=0;i<2;i++){
   const e=this.eyeGroups[i],pose=i?motion.right:motion.left,happy=MathUtils.smoothstep(pose.curve,.033,.083),heart=MathUtils.smoothstep(pose.heart,.3,.8),x=e.side*.305+pose.x*.55,y=.035+pose.y*.65;
   e.group.position.set(x,y,this.surfaceZ(x,y)+.026);e.group.rotation.z=pose.tilt;
   const openness=Math.max(.055,pose.open),height=MathUtils.clamp(pose.height/.45,.40,1.15),width=MathUtils.clamp(pose.width/.235,.92,1.20);
   e.bead.visible=happy<.55&&heart<.55;e.socket.visible=e.bead.visible;e.arc.visible=happy>=.55&&heart<.55;e.love.visible=heart>=.55;
   e.bead.scale.set(.101*width,.112*height*openness,.069);e.socket.scale.set(.119*width,.128*height*openness,.039);
   e.arc.scale.set(width,openness,1);e.love.scale.set(1,openness,1);
  }
  let width=.30,curve=.145,y=-.285,radius=.064,open=0;
  switch(motion.expression){
   case 'attentive':width=.18;curve=.075;radius=.043;open=.034;y=-.25;break;
   case 'pondering':width=.14;curve=.025;radius=.040;y=-.245;break;
   case 'focused':width=.20;curve=.050;radius=.042;y=-.26;break;
   case 'engaged':width=.25;curve=.11;radius=.046;open=.027+(!reduced?Math.sin(t*7.1)**2*.045:0);break;
   case 'happy':case 'love':width=.34;curve=.17;radius=.066;break;
   case 'wink':width=.31;curve=.15;break;
   case 'concerned':width=.19;curve=-.052;radius=.039;y=-.205;break;
   case 'curious':width=.24;curve=.10;radius=.047;break;
   case 'sleepy':case 'soft-close':width=.18;curve=.065;radius=.042;y=-.255;break;
  }
  this.updateMouth(width,curve,y,radius,open);
 }
 stats(){return {expression:this.expression,petals:6,bodyVertices:this.body.geometry.attributes.position.count,bodyTriangles:this.body.geometry.index.count/3,visible:this.group.visible};}
}
