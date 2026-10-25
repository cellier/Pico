const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');

// Use the production meshes, transforms, eye rig, raycasting and bridge. Only
// DOM/WebGL presentation is stubbed; these tests never open UI or user data.
function loadAvatar(edge = 26) {
  let now = 1000, drawingBufferResets = 0;
  const noop = () => {};
  const context2d = {createRadialGradient: () => ({addColorStop: noop}), fillRect: noop};
  const window = {
    innerWidth: edge, innerHeight: edge,
    matchMedia: () => ({matches: false, addEventListener: noop}), addEventListener: noop,
  };
  const sandbox = {
    document: {createElement: () => ({getContext: () => context2d}), body: {appendChild: noop}},
    window, innerWidth: edge, innerHeight: edge, devicePixelRatio: 2,
    performance: {now: () => now}, setTimeout: noop, console,
    resetDrawingBuffer: () => {drawingBufferResets++;},
  };
  const context = vm.createContext(sandbox);
  const run = source => vm.runInContext(source, context);
  run(fs.readFileSync(path.join(root, 'Pico/vendor/three.module.js'), 'utf8').replace(/export \{[^}]+\};\s*$/, ''));
  run(`
    WebGLRenderer = class {
      constructor() {this.domElement = {style: {}}; this.shadowMap = {}; this.info = {render: {triangles: 0}}; this.ratio = 1;}
      setSize() {} setPixelRatio(value) {this.ratio = value;} getPixelRatio() {return this.ratio;}
      setClearColor() {} setDrawingBufferSize(width, height, ratio) {this.ratio = ratio; resetDrawingBuffer();}
      getContext() {return {getContextAttributes: () => ({alpha: true})};}
      render(scene, camera) {scene.updateMatrixWorld(true); camera.updateMatrixWorld(true);}
      dispose() {}
    };
    PMREMGenerator = class {fromScene() {return {texture: new Texture()};} dispose() {}};
  `);
  for (const file of ['eyes.js', 'flower.js', 'orb.js', 'pet.js'])
    run(fs.readFileSync(path.join(root, 'Pico', file), 'utf8'));
  run(fs.readFileSync(path.join(root, 'Resources/PicoAvatarBridge.js'), 'utf8'));
  return {
    run,
    stats: () => JSON.parse(run('JSON.stringify(window.petStats())')),
    pointer: () => JSON.parse(run('JSON.stringify(pointer)')),
    viewport: () => JSON.parse(run('JSON.stringify(petViewport)')),
    drawingBufferResets: () => drawingBufferResets,
    point(x, y) {return run(`window.picoAvatar.pointerAt(${x}, ${y})`);},
    advance(frames = 30) {
      for (let i = 0; i < frames; i++) {now += 1000 / 30; run('animate(1/30)');}
    },
    normal() {
      return JSON.parse(run(`JSON.stringify((() => {
        scene.updateMatrixWorld(true);
        return new Vector3(0, 0, 1).applyQuaternion(activeSkin().getWorldQuaternion(new Quaternion())).toArray();
      })())`));
    },
  };
}

function close(a, b, message) {assert.ok(Math.abs(a - b) < 1e-9, message || `${a} != ${b}`);}

test('normalized directions reach the real shared pointer at every avatar size', () => {
  for (const edge of [26, 36, 52, 179.2]) {
    const avatar = loadAvatar(edge);
    for (const [x, y] of [[0, 0], [-1, 0], [1, 0], [0, -1], [0, 1], [.65, -.4], [3, -2]]) {
      avatar.point(x, y);
      close(avatar.pointer().x, x); close(avatar.pointer().y, y);
    }
  }
});

test('resize and Retina changes preserve CSS pointer mapping without repeated buffer resets', () => {
  const avatar = loadAvatar();
  for (const edge of [36, 52, 179.2, 26]) for (const ratio of [1, 2]) {
    avatar.run(`window.picoAvatar.resize(${edge}, ${edge}, ${ratio})`);
    assert.deepEqual(avatar.viewport(), {width: edge, height: edge});
    avatar.point(.5, -.25);
    close(avatar.pointer().x, .5); close(avatar.pointer().y, -.25);
    const count = avatar.drawingBufferResets();
    avatar.run(`window.picoAvatar.resize(${edge}, ${edge}, ${ratio})`);
    assert.equal(avatar.drawingBufferResets(), count, 'Unchanged layout must not reset the WebGL canvas');
    assert.equal(avatar.stats().pixelRatio, ratio);
  }
});

test('all three real skins turn their head and eyes in the pointer direction', () => {
  for (const skin of ['classic', 'blossom', 'snowball']) {
    const avatar = loadAvatar();
    avatar.run(`window.picoAvatar.configure({skin: '${skin}', state: 'idle'})`);
    for (const direction of [-.65, .65]) {
      avatar.point(direction, 0); avatar.advance();
      assert.ok(avatar.normal()[0] * direction > .08, `${skin} head must follow left/right`);
      assert.ok(avatar.stats().eyes.left.x * direction > .01, `${skin} eyes must follow left/right`);
    }
    for (const direction of [-.65, .65]) {
      avatar.point(0, direction); avatar.advance();
      assert.ok(avatar.normal()[1] * direction > .035, `${skin} head must follow up/down`);
      assert.ok(avatar.stats().eyes.left.y * direction > .008, `${skin} eyes must follow up/down`);
    }
  }
});

test('old 280pt coordinates demonstrate the regression and the normalized bridge fixes it', () => {
  const avatar = loadAvatar(26);
  avatar.run('window.pointerAt(210, 140)'); avatar.advance();
  assert.ok(Math.abs(avatar.pointer().x) > 2.6 && Math.abs(avatar.pointer().y) > 2.6,
    'The former native mapping incorrectly tells the 26pt avatar the pointer is far away');
  assert.ok(Math.abs(avatar.normal()[0]) < .02, 'The shared distance fade suppresses that incorrect direction');
  avatar.point(.5, 0); avatar.advance();
  assert.ok(avatar.normal()[0] > .15, 'The new bridge must restore actual rendered head direction');
});

test('pause/resume, expression updates and skin changes retain the current pointer', () => {
  const avatar = loadAvatar();
  avatar.point(.6, .3); avatar.advance();
  const time = avatar.stats().animationTime;
  avatar.run("window.setPaused(true); window.picoAvatar.configure({skin: 'classic', state: 'thinking'})");
  close(avatar.pointer().x, .6); close(avatar.pointer().y, .3);
  assert.equal(avatar.stats().paused, true); close(avatar.stats().animationTime, time);
  avatar.point(-.6, -.3);
  avatar.run("window.picoAvatar.configure({skin: 'snowball', state: 'idle'}); window.setPaused(false)");
  avatar.advance();
  close(avatar.pointer().x, -.6); close(avatar.pointer().y, -.3);
  assert.ok(avatar.normal()[0] < -.15 && avatar.stats().eyes.left.x < -.02);
});

test('non-finite directions are ignored without changing the last valid pointer', () => {
  const avatar = loadAvatar();
  avatar.point(.5, -.25);
  for (const args of ['NaN, 0', '0, Infinity', '-Infinity, NaN'])
    assert.equal(avatar.run(`window.picoAvatar.pointerAt(${args})`), false);
  assert.deepEqual(avatar.pointer(), {x: .5, y: -.25});
});
