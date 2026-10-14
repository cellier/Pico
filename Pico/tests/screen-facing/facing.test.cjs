const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const skins = ['classic', 'blossom', 'snowball'];

// Keep production transforms, geometry, raycasting, and state logic. Only the
// unavailable WebGL renderer and DOM are stubbed; native captures assess visuals.
function loadPet() {
  let renders = 0, now = 1000;
  const noop = () => {};
  const context2d = {createRadialGradient: () => ({addColorStop: noop}), fillRect: noop};
  const document = {createElement: () => ({width: 0, height: 0, getContext: () => context2d}), body: {appendChild: noop}};
  const window = {matchMedia: () => ({matches: false, addEventListener: noop}), addEventListener: noop};
  const sandbox = {document, window, devicePixelRatio: 2, performance: {now: () => now}, setTimeout: noop, console};
  const context = vm.createContext(sandbox);
  const vendor = fs.readFileSync(path.join(root, 'vendor/three.module.js'), 'utf8').replace(/export \{[^}]+\};\s*$/, '');
  vm.runInContext(vendor, context);
  sandbox.countRender = () => {renders++;};
  vm.runInContext(`
    WebGLRenderer=class {
      constructor(){this.domElement={};this.shadowMap={};this.info={render:{triangles:0}};this.ratio=1;}
      setSize(){} setPixelRatio(value){this.ratio=value;} getPixelRatio(){return this.ratio;}
      setClearColor(){} getContext(){return {getContextAttributes:()=>({alpha:true})};}
      render(scene,camera){scene.updateMatrixWorld(true);camera.updateMatrixWorld(true);countRender();}
    };
    PMREMGenerator=class {fromScene(){return {texture:new Texture()};}dispose(){}};
  `, context);
  for (const filename of ['eyes.js', 'flower.js', 'orb.js', 'pet.js'])
    vm.runInContext(fs.readFileSync(path.join(root, filename), 'utf8'), context);
  return {
    run: source => vm.runInContext(source, context),
    stats: () => JSON.parse(vm.runInContext('JSON.stringify(window.petStats())', context)),
    renders: () => renders,
    elapse: milliseconds => {now += milliseconds;},
  };
}
function advance(pet, frames = 180) {pet.run(`for(let i=0;i<${frames};i++)animate(1/30)`);}
function setSkin(pet, skin) {pet.run(`window.setSkin(${JSON.stringify(skin)})`);}
function faceNormal(pet) {
  return JSON.parse(pet.run(`JSON.stringify((()=>{
    scene.updateMatrixWorld(true);
    return new Vector3(0,0,1).applyQuaternion(activeSkin().getWorldQuaternion(new Quaternion())).toArray();
  })())`));
}
function stableState(stats) {
  return {
    state: stats.state, eyeState: stats.eyes.state, elapsed: stats.eyes.elapsed,
    animationTime: stats.animationTime, weights: stats.weights,
    interaction: stats.interaction, springs: stats.springs,
    paused: stats.paused, reducedMotion: stats.reducedMotion,
  };
}
function assertFinitePose(pet) {
  const stats = pet.stats();
  assert.ok(stats.rotation.every(Number.isFinite), 'Head rotation must remain finite');
  assert.ok(faceNormal(pet).every(Number.isFinite), 'Skin face normal must remain finite');
  assert.ok(Number.isFinite(stats.screenFacing.x) && Math.abs(stats.screenFacing.x) <= 1);
  assert.ok(Number.isFinite(stats.screenFacing.y) && Math.abs(stats.screenFacing.y) <= 1);
}

test('preview without a native screen position retains its established resting pose', () => {
  const pet = loadPet();
  advance(pet);
  const stats = pet.stats();
  assert.ok(Math.abs(stats.rotation[0] - .02) < 1e-8);
  assert.ok(Math.abs(stats.rotation[1] + .085) < 1e-8);
  for (const skin of skins) {
    setSkin(pet, skin);
    const normal = faceNormal(pet);
    const expectedYaw = skin === 'snowball' ? .32 - .085 : -.085;
    assert.ok(Math.abs(Math.atan2(normal[0], normal[2]) - expectedYaw) < .001,
      `${skin} preview should keep its existing local resting angle until native placement is known`);
  }
});

test('all skins face inward from left, right, top, and bottom screen placements', () => {
  for (const skin of skins) {
    const pet = loadPet();setSkin(pet, skin);
    for (const [x, y] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      pet.run(`window.setScreenFacing(${x},${y})`);advance(pet);
      const stats = pet.stats(), normal = faceNormal(pet);
      assert.equal(stats.screenFacing.x, x);assert.equal(stats.screenFacing.y, y);
      if (x) assert.ok(normal[0] * x > .08, `${skin} should face ${x > 0 ? 'right' : 'left'}, got ${normal}`);
      if (y) assert.ok(normal[1] * y > .05, `${skin} should face ${y > 0 ? 'up' : 'down'}, got ${normal}`);
      assert.ok(Math.abs(normal[0]) < .20 && Math.abs(normal[1]) < .13, `${skin} resting glance should remain subtle at screen edges: ${normal}`);
      assertFinitePose(pet);
    }
  }
});

test('skin switching compensates the white balloon local yaw without reversing the facing direction', () => {
  const pet = loadPet();pet.run('window.setScreenFacing(-.9,.45)');advance(pet);
  for (let cycle = 0; cycle < 3; cycle++) for (const skin of skins) {
    setSkin(pet, skin);advance(pet, 120);
    const normal = faceNormal(pet);
    assert.ok(normal[0] < -.08 && normal[1] > .01, `${skin} lost inward facing: ${normal}`);
    assert.deepEqual(pet.stats().screenFacing, {x: -.9, y: .45});
  }
  pet.run('window.setScreenFacing(0,0)');advance(pet);
  for (const skin of skins) {
    setSkin(pet, skin);advance(pet, 120);
    assert.ok(Math.abs(faceNormal(pet)[0]) < .03, `${skin} should look forward at screen center`);
  }
});

test('screen-facing input clamps extremes and safely rejects non-finite coordinates', () => {
  const pet = loadPet();
  pet.run('window.setScreenFacing(5,-8)');advance(pet);
  assert.deepEqual(pet.stats().screenFacing, {x: 1, y: -1});
  for (const args of ['NaN,Infinity', '-Infinity,NaN', 'undefined,undefined', 'null,null', '"bad",{}']) {
    assert.doesNotThrow(() => pet.run(`window.setScreenFacing(${args})`));
    advance(pet, 30);assertFinitePose(pet);
  }
});

test('placement updates preserve held interaction and active voice or work state', () => {
  const pet = loadPet();
  for (const [emotion, state] of [['listening', 'meeting'], ['transcribing', 'thinking'], ['thinking', 'thinking'], ['working', 'working'], ['speaking', 'meeting']]) {
    pet.run(`window.sprout.setEmotion(${JSON.stringify(emotion)});window.setPetState(${JSON.stringify(state)});window.setPressed(true)`);
    advance(pet, 30);
    const before = stableState(pet.stats());
    pet.run('window.setScreenFacing(.85,-.6)');
    assert.deepEqual(stableState(pet.stats()), before, `Placement update reset ${emotion}`);
    advance(pet, 60);
    const after = pet.stats();
    assert.equal(after.state, state);assert.equal(after.eyes.state, emotion);
    assert.equal(after.interaction.down, true);
    assert.equal(after.orb.sourceExpression, after.eyes.expression);
    assertFinitePose(pet);
    pet.run('window.setPressed(false)');
  }
});

test('paused and reduced-motion placement changes render immediately without advancing clocks', () => {
  for (const mode of ['paused', 'reduced']) for (const skin of skins) {
    const pet = loadPet();setSkin(pet, skin);
    pet.run("window.sprout.setEmotion('listening');window.setPetState('meeting')");advance(pet, 30);
    pet.run(mode === 'paused' ? 'window.setPaused(true)' : 'window.setReducedMotion(true)');
    pet.run('window.setPressed(true)');
    const before = stableState(pet.stats()), count = pet.renders();
    pet.run('window.setScreenFacing(-1,1)');
    assert.ok(pet.renders() > count, `${mode} ${skin} must show the new pose immediately`);
    assert.deepEqual(stableState(pet.stats()), before, `${mode} placement must not advance motion or reset voice/press`);
    const normal = faceNormal(pet);
    assert.ok(normal[0] < -.08 && normal[1] > .01, `${mode} ${skin} did not apply the pose immediately: ${normal}`);
  }
});

test('nearby moving pointer is temporary; stale pointer returns to screen-center facing', () => {
  const pet = loadPet();pet.run('window.setScreenFacing(-1,0)');advance(pet);
  const resting = faceNormal(pet);
  assert.ok(resting[0] < -.08);
  pet.run('window.pointerAt(240,140)');advance(pet, 90);
  const attentive = faceNormal(pet);
  assert.ok(attentive[0] > resting[0] + .08, 'A nearby moving pointer should still draw a temporary look');
  pet.elapse(6000);advance(pet);
  const returned = faceNormal(pet);
  assert.ok(Math.abs(returned[0] - resting[0]) < .01, 'Stale pointer must release its look back to the screen center');
  assert.deepEqual(pet.stats().screenFacing, {x: -1, y: 0});
});

test('hit testing follows the newly posed active geometry and ignores transparent corners', () => {
  const pet = loadPet();
  for (const skin of skins) for (const [x, y] of [[1, .7], [-1, -.7]]) {
    setSkin(pet, skin);pet.run(`window.setScreenFacing(${x},${y})`);advance(pet);
    const result = pet.run(`(()=>{
      let mismatches=0,hits=0;
      for(let y=10;y<280;y+=13)for(let x=10;x<280;x+=13){
        const actual=window.pointerAt(x,y);
        const expected=ray.intersectObjects([activeSkin(),...[work,think,meeting].filter(g=>g.visible)],true).some(hit=>interactive(hit.object));
        if(actual!==expected)mismatches++;
        if(actual)hits++;
      }
      return {mismatches,hits};
    })()`);
    assert.equal(result.mismatches, 0);assert.ok(result.hits > 10, `${skin} must remain interactive after rotation`);
    for (const [px, py] of [[0, 0], [279, 0], [0, 279], [279, 279]])
      assert.equal(pet.run(`window.pointerAt(${px},${py})`), false, `${skin} intercepted a transparent corner`);
  }
});
