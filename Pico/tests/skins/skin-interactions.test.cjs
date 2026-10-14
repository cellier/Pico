const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const skins = ['classic','blossom','snowball'];

// Exercise production geometry, transforms and raycasting without browser/UI/audio.
// Only the renderer and DOM are stubbed; visual fidelity belongs to native snapshots.
function loadPet() {
  let renders = 0;
  const noop = () => {};
  const context2d = { createRadialGradient: () => ({addColorStop: noop}), fillRect: noop };
  const document = { createElement: () => ({width: 0, height: 0, getContext: () => context2d}), body: {appendChild: noop} };
  const window = { matchMedia: () => ({matches: false, addEventListener: noop}), addEventListener: noop };
  const sandbox = { document, window, devicePixelRatio: 2, performance: {now: () => 1000}, setTimeout: noop, console };
  const ctx = vm.createContext(sandbox);
  const vendor = fs.readFileSync(path.join(root, 'vendor/three.module.js'), 'utf8').replace(/export \{[^}]+\};\s*$/, '');
  vm.runInContext(vendor, ctx);
  sandbox.countRender = () => { renders++; };
  vm.runInContext(`
    WebGLRenderer=class {
      constructor(){this.domElement={};this.shadowMap={};this.info={render:{triangles:0}};this.ratio=1;}
      setSize(){} setPixelRatio(value){this.ratio=value;} getPixelRatio(){return this.ratio;}
      setClearColor(){} getContext(){return {getContextAttributes:()=>({alpha:true})};}
      render(scene,camera){scene.updateMatrixWorld(true);camera.updateMatrixWorld(true);countRender();}
    };
    PMREMGenerator=class {fromScene(){return {texture:new Texture()};}dispose(){}};
  `, ctx);
  vm.runInContext(fs.readFileSync(path.join(root, 'eyes.js'), 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(path.join(root, 'flower.js'), 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(path.join(root, 'orb.js'), 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(path.join(root, 'pet.js'), 'utf8'), ctx);
  return {run: source => vm.runInContext(source, ctx), renders: () => renders,
    stats: () => JSON.parse(vm.runInContext('JSON.stringify(window.petStats())', ctx))};
}
function setSkin(pet, name) { return pet.run(`(window.setSkin||window.sprout.setSkin)(${JSON.stringify(name)})`); }
function getSkin(pet) { return pet.run('(window.getSkin||window.sprout.getSkin)()'); }
function advance(pet, frames = 30) { pet.run(`for(let i=0;i<${frames};i++)animate(1/30)`); }
function assertDefaultFace(orb) {
  assert.equal(orb.defaultFace,true);
  assert.equal(orb.expression,'attentive');
  assert.deepEqual(orb.eyeSizes[0],orb.eyeSizes[1],'Resting eyes must have the same local dimensions');
  assert.equal(orb.eyeCenters[0][1],orb.eyeCenters[1][1],'Resting eyes must sit at the same local height');
  assert.deepEqual(orb.eyePrimitives,['ellipse','ellipse']);
  assert.deepEqual(orb.eyeHearts,[0,0]);
  assert.equal(orb.mouthPrimitive,'capsule');assert.equal(orb.mouthCurve,0);assert.equal(orb.mouthTilt,0);
  assert.ok(Math.abs(orb.mouthSize[0]*2-.44)<1e-8 && Math.abs(orb.mouthSize[1]*2-.112)<1e-8,
    'The latest default should use the listening-style mouth, slightly longer than while held');
}
function assertRigidHearts(orb) {
  assert.deepEqual(orb.eyePrimitives,['heart','heart']);
  assert.deepEqual(orb.eyeHearts,[1,1]);
  assert.deepEqual(orb.heartScales,[.108,.108]);
  assert.deepEqual(orb.eyeOpenness,[1,1],'Heart silhouettes must ignore blink compression');
  assert.deepEqual(orb.eyeSizes,[[.108,.108],[.108,.108]],'Each heart uses one uniform scale, independent of shared eye proportions');
}

test('white balloon is the actual default and fallback, while every saved valid skin remains selectable', () => {
  const pet=loadPet();
  assert.equal(getSkin(pet), 'snowball');
  assert.equal(pet.run('orbRig.group.visible && !classicSkin.visible && !flowerRig.group.visible'),true,
    'The initial visible scene must agree with the default skin setting');
  assert.equal(pet.run('activeSkin()===orbRig.group && activeEye()===orbRig.eyeMeshes[0]'),true);
  for(const skin of skins){
    setSkin(pet,skin);assert.equal(getSkin(pet),skin);
    assert.equal(pet.run(`Object.entries(skinGroups).every(([name,group])=>group.visible===(name===${JSON.stringify(skin)}))`),true);
  }
  for(const value of ['unknown','',null,undefined]){
    setSkin(pet,value);assert.equal(getSkin(pet),'snowball');
    assert.equal(pet.run('orbRig.group.visible && !classicSkin.visible && !flowerRig.group.visible'),true);
  }
});

test('switching preserves pressed interaction, current task and shared motion', () => {
  const pet=loadPet();
  pet.run("window.setPetState('working');window.sprout.setEmotion('working');window.setPressed(true)");
  advance(pet);
  const before=pet.stats();
  for(let i=0;i<30;i++)setSkin(pet, skins[i%skins.length]);
  const after=pet.stats();
  for(const key of ['state','weights','interaction','springs','animationTime','rotation','props'])
    assert.deepEqual(after[key], before[key], `Skin swap changed ${key}`);
  assert.equal(after.eyes.state, before.eyes.state);
  assert.equal(after.eyes.elapsed, before.eyes.elapsed);
  pet.run('window.setPressed(false)');advance(pet);
  assert.equal(pet.stats().interaction.down, false);
  assert.ok(Math.abs(pet.stats().interaction.x-1)<.002);
});

test('paused skin switching renders immediately without resuming the animation clock', () => {
  const pet=loadPet();pet.run("window.setPetState('thinking');window.sprout.setEmotion('thinking')");advance(pet);
  pet.run('window.setPaused(true)');const before=pet.stats();
  for(const skin of ['blossom','snowball','classic']){
    const renders=pet.renders();setSkin(pet,skin);const after=pet.stats();
    assert.ok(pet.renders()>renders, 'Paused swap must produce a frame');
    assert.equal(after.paused,true);assert.equal(after.animationTime,before.animationTime);
    assert.equal(after.eyes.elapsed,before.eyes.elapsed);assert.equal(after.state,'thinking');
    if(skin==='blossom')assert.equal(after.flower.expression,after.eyes.expression,'Paused swap must refresh the flower to the current expression');
    if(skin==='snowball')assert.equal(after.orb.sourceExpression,after.eyes.expression,'Paused swap must refresh the snowball from the current shared expression');
  }
  pet.run('window.setPressed(true)');
  assert.equal(pet.stats().interaction.x,.95);
  setSkin(pet,'classic');assert.equal(pet.stats().interaction.x,.95);
});

test('all three skins reuse geometry and buffers across animation and repeated switches', () => {
  const pet=loadPet();
  pet.run(`
    const skinGeometries=new Map(), skinMaterials=new Set(), skinNodes=new Set();
    pet.traverse(node=>{skinNodes.add(node);if(node.geometry)skinGeometries.set(node.geometry,[node.geometry.attributes.position.array,node.geometry.attributes.normal?.array,node.geometry.index?.array]);if(node.material)skinMaterials.add(node.material);});
    for(let cycle=0;cycle<12;cycle++){
      window.setSkin(['classic','blossom','snowball'][cycle%3]);window.sprout.setEmotion(cycle%2?'working':'speaking');
      for(let frame=0;frame<15;frame++)animate(1/30);
    }
  `);
  assert.equal(pet.run(`(()=>{
    let valid=true,count=0;pet.traverse(node=>{count++;if(!skinNodes.has(node))valid=false;
      if(node.material&&!skinMaterials.has(node.material))valid=false;
      if(node.geometry){const old=skinGeometries.get(node.geometry);if(!old||old[0]!==node.geometry.attributes.position.array||old[1]!==node.geometry.attributes.normal?.array||old[2]!==node.geometry.index?.array)valid=false;}
    });return valid&&count===skinNodes.size;
  })()`),true,'Skin animation must not grow the scene or replace geometry/material/buffers');
});

test('reduced motion freezes the new speech-mouth pulse and shared expressions reach flower eyes', () => {
  const pet=loadPet();setSkin(pet,'blossom');
  pet.run("window.setReducedMotion(true);window.sprout.setEmotion('speaking')");advance(pet);
  const before=pet.run('flowerRig.openMouth.scale.y');advance(pet,17);
  assert.equal(pet.run('flowerRig.openMouth.scale.y'),before);
  pet.run("window.sprout.setEmotion('completed')");advance(pet,30);
  assert.equal(pet.run("flowerRig.expression==='happy' && flowerRig.eyeGroups.every(eye=>eye.arc.visible&&!eye.bead.visible&&!eye.love.visible)"),true);
});

test('cached smile retains dynamic speech opening and refreshes on expression change', () => {
  const pet=loadPet();setSkin(pet,'blossom');
  assert.ok(pet.run('flowerRig.mouthGeometry.attributes.position.array.some(value=>value!==0)'), 'First update must initialize the smile');
  pet.run('flowerRig.updateMouth(.30,.135,-.285,.053,0)');
  const version=pet.run('flowerRig.mouthGeometry.attributes.position.version');
  pet.run('for(let i=0;i<90;i++)flowerRig.updateMouth(.30,.135,-.285,.053,.06)');
  assert.equal(pet.run('flowerRig.mouthGeometry.attributes.position.version'),version,'Unchanged smile must not be regenerated/uploaded');
  assert.equal(pet.run('flowerRig.openMouth.visible && flowerRig.openMouth.scale.y===.06'),true,'Cached smile must still animate inner speech mouth');
  pet.run('flowerRig.updateMouth(.19,-.052,-.205,.039,0)');
  assert.ok(pet.run('flowerRig.mouthGeometry.attributes.position.version')>version,'Changed expression must refresh smile geometry');
  assert.equal(pet.run('flowerRig.openMouth.visible'),false);
});

test('reduced motion and semantic eye state survive all skin directions', () => {
  const pet=loadPet();pet.run("window.setReducedMotion(true);window.sprout.setEmotion('listening');window.setPetState('meeting')");advance(pet);
  for(const skin of ['blossom','snowball','classic']) {
    const before=pet.stats();setSkin(pet,skin);const after=pet.stats();
    assert.equal(after.reducedMotion,true);assert.equal(after.eyes.state,'listening');
    assert.equal(after.animationTime,before.animationTime);
    pet.run('window.setPressed(true)');assert.equal(pet.stats().interaction.x,.95);
    pet.run('window.setPressed(false)');assert.equal(pet.stats().interaction.x,1);
  }
});

test('snowball follows the same voice/task emotions without consuming or resetting shared motion', () => {
  const pet=loadPet();setSkin(pet,'snowball');
  for(const state of ['idle','listening','transcribing','thinking','working','speaking','completed','error','needs_input','awaiting_approval','cancelled']){
    pet.run(`window.sprout.setEmotion(${JSON.stringify(state)})`);advance(pet,18);
    assert.equal(pet.stats().orb.sourceExpression,pet.stats().eyes.expression,`Snowball lost ${state} source expression`);
    const before=pet.stats();
    setSkin(pet,'classic');setSkin(pet,'blossom');setSkin(pet,'snowball');
    const after=pet.stats();
    assert.equal(after.eyes.state,state);assert.equal(after.eyes.elapsed,before.eyes.elapsed);
    assert.equal(after.orb.sourceExpression,after.eyes.expression);
  }
});

test('snowball rests with symmetric listening-style eyes during idle, hover, input and approval', () => {
  const pet=loadPet();setSkin(pet,'snowball');
  pet.run('window.setReducedMotion(true)');
  for(const state of ['idle','needs_input','awaiting_approval']) {
    pet.run(`window.sprout.setEmotion(${JSON.stringify(state)})`);advance(pet,18);
    const stats=pet.stats();assertDefaultFace(stats.orb);assert.equal(stats.eyes.state,state);
    assert.ok(Math.abs(stats.orb.eyeSizes[0][0]-.1045)<.0001 && Math.abs(stats.orb.eyeSizes[0][1]-.1031)<.0001);
    if(state!=='idle')assert.notEqual(stats.eyes.left.height,stats.eyes.right.height,'White styling must not rewrite the shared curious pose');
    assert.equal(stats.orb.sourceExpression,stats.eyes.expression);
  }
  pet.run("window.sprout.setEmotion('idle');window.pointerAt(200,100)");advance(pet,18);
  assert.equal(pet.stats().eyes.expression,'curious','Exercise the actual hover expression that caused unequal eyes');
  assertDefaultFace(pet.stats().orb);
  pet.run('window.setReducedMotion(false);eyeRig.motion.nextBlink=Infinity;eyeRig.motion.blinkStart=eyeRig.motion.time');advance(pet,3);
  assert.ok(pet.stats().eyes.left.open<.1,'Exercise the closed part of a blink');
  assertDefaultFace(pet.stats().orb);
});

test('snowball hold and listening retain their shorter mouth across paused and reduced-motion switches', () => {
  const pet=loadPet();setSkin(pet,'snowball');
  pet.run("window.setReducedMotion(true);window.sprout.setEmotion('needs_input')");advance(pet,18);
  const resting=pet.stats().orb;
  pet.run('window.setPaused(true);window.setPressed(true)');
  for(const skin of ['classic','blossom','snowball'])setSkin(pet,skin);
  const held=pet.stats();
  assert.equal(held.paused,true);assert.equal(held.interaction.down,true);assert.equal(held.eyes.state,'needs_input');
  assert.equal(held.orb.expression,'attentive');assert.equal(held.orb.defaultFace,false);
  assert.deepEqual(held.orb.eyeSizes,resting.eyeSizes);
  assert.deepEqual(held.orb.mouthSize,[.19,.056]);
  assert.ok(resting.mouthSize[0]>held.orb.mouthSize[0]);
  pet.run('window.setPressed(false)');assertDefaultFace(pet.stats().orb);
  pet.run("window.setPaused(false);window.sprout.setEmotion('listening');window.setPetState('meeting')");advance(pet,18);
  assert.deepEqual(pet.stats().orb.mouthSize,[.19,.056]);assert.equal(pet.stats().state,'meeting');
});

test('snowball explicit wink is brief, then returns to a symmetric default without clearing a waiting task', () => {
  const pet=loadPet();setSkin(pet,'snowball');pet.run('window.setReducedMotion(true)');
  for(const state of ['idle','needs_input','awaiting_approval']) {
    pet.run(`window.sprout.setEmotion(${JSON.stringify(state)});eyeRig.motion.tapCount=1;window.cheer()`);advance(pet,18);
    const wink=pet.stats().orb;
    assert.equal(wink.expression,'wink');assert.equal(wink.mouthPrimitive,'capsule');assert.equal(wink.mouthCurve,0);
    assert.ok(wink.eyeSizes[0][1]<wink.eyeSizes[1][1]*.3,'Only the explicit wink should briefly close one eye');
    assert.ok(Math.abs(wink.mouthTilt)>.05 && Math.abs(wink.mouthTilt)<.3,'Wink rotates one regular capsule');
    assert.equal(pet.stats().eyes.state,state);
    advance(pet,62);
    assertDefaultFace(pet.stats().orb);assert.equal(pet.stats().eyes.state,state);
    assert.equal(pet.run('eyeRig.motion.gesture'),null,'Gesture must expire after 2.6 seconds');
  }
});

test('snowball happy and love hearts keep rigid proportions through shared pose transitions and blinks', () => {
  const pet=loadPet();setSkin(pet,'snowball');
  for(const state of ['idle','needs_input','awaiting_approval'])for(const [tapCount,expression] of [[0,'happy'],[2,'love']]) {
    pet.run(`window.sprout.setEmotion(${JSON.stringify(state)});eyeRig.motion.tapCount=${tapCount};window.cheer();eyeRig.motion.nextBlink=Infinity`);advance(pet,1);
    const before=pet.stats().orb;
    assert.equal(before.expression,expression);assertRigidHearts(before);
    assert.equal(before.mouthPrimitive,'roundArc');assert.ok(before.mouthCurve>0 && before.mouthSize[1]>0);
    pet.run('eyeRig.motion.blinkStart=eyeRig.motion.time');advance(pet,3);
    assert.ok(pet.stats().eyes.left.open<.1,'Test hearts while the shared eyelids are closed');
    const during=pet.stats().orb;assertRigidHearts(during);
    assert.deepEqual(during.mouthSize,before.mouthSize);assert.equal(during.mouthCurve,before.mouthCurve);
    assert.equal(pet.stats().eyes.state,state);
    advance(pet,76);assertDefaultFace(pet.stats().orb);
  }
});

test('snowball affectionate waiting gestures yield immediately to holding and active voice or work', () => {
  const pet=loadPet();setSkin(pet,'snowball');
  pet.run("window.setReducedMotion(true);window.sprout.setEmotion('needs_input');window.cheer()");advance(pet,1);
  assertRigidHearts(pet.stats().orb);
  pet.run('window.setPressed(true)');
  assert.equal(pet.stats().orb.expression,'attentive');assert.deepEqual(pet.stats().orb.eyeHearts,[0,0]);
  assert.equal(pet.stats().eyes.state,'needs_input');assert.equal(pet.stats().interaction.down,true);
  advance(pet,80);pet.run('window.setPressed(false)');advance(pet,1);assertDefaultFace(pet.stats().orb);
  for(const [state,prop] of [['listening','meeting'],['transcribing','thinking'],['thinking','thinking'],['working','working'],['speaking','meeting']]) {
    pet.run(`window.sprout.setEmotion(${JSON.stringify(state)});window.setPetState(${JSON.stringify(prop)});eyeRig.motion.tapCount=2;window.cheer()`);advance(pet,1);
    assert.equal(pet.stats().eyes.state,state);assert.equal(pet.stats().state,prop);
    assert.equal(pet.stats().orb.sourceExpression,pet.stats().eyes.expression);
    assert.equal(pet.stats().orb.expression,pet.stats().eyes.expression);
    assert.deepEqual(pet.stats().orb.eyeHearts,[0,0],`${state} must take priority over an affectionate click`);
  }
});

test('only visible active geometry intercepts clicks; transparent corners remain pass-through', () => {
  const pet=loadPet();
  for(const skin of skins) {
    setSkin(pet,skin);
    assert.equal(pet.run('window.pointerAt(140,140)'),true,`${skin} face should be interactive`);
    for(const [x,y] of [[0,0],[0,279],[279,0],[279,279],[-30,140],[310,140]])
      assert.equal(pet.run(`window.pointerAt(${x},${y})`),false,`${skin} intercepted empty corner ${x},${y}`);
    const result=pet.run(`(()=>{
      let hiddenHits=0, wrongHits=0;
      for(let y=20;y<260;y+=8)for(let x=20;x<260;x+=8){
        const actual=window.pointerAt(x,y);
        const hits=ray.intersectObject(pet,true);
        const valid=hits.some(hit=>{for(let node=hit.object;node;node=node.parent)if(!node.visible||node.userData.passThrough)return false;return true;});
        hiddenHits+=hits.filter(hit=>{for(let node=hit.object;node;node=node.parent)if(!node.visible)return true;return false;}).length;
        if(actual!==valid)wrongHits++;
      }
      return {hiddenHits,wrongHits};
    })()`);
    assert.ok(result.hiddenHits>0,'Other skin groups must remain present for this exclusion check');
    assert.equal(result.wrongHits,0,`${skin} used hidden geometry in hit testing`);
  }
});
