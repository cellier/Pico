const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Run the production motion model without a browser, graphics mocks or audio.
const source = fs.readFileSync(path.join(__dirname, '../../eyes.js'), 'utf8');
const sandbox = {};
vm.runInNewContext(source + '\nthis.PicoEyeMotion = PicoEyeMotion;', sandbox);
const Model = sandbox.PicoEyeMotion;
const states = ['idle', 'listening', 'transcribing', 'thinking', 'working', 'speaking', 'completed', 'error', 'needs_input', 'awaiting_approval', 'cancelled'];
function advance(model, seconds, input = {}) {
  for (let remaining = seconds; remaining > 1e-9;) {
    const dt = Math.min(1 / 60, remaining);
    model.update(dt, input);
    remaining -= dt;
  }
  return model;
}
function close(actual, expected, tolerance = 1e-4) {
  assert.ok(Math.abs(actual - expected) < tolerance, `${actual} differs from ${expected}`);
}

test('voice and task transitions convey distinct appropriate expressions', () => {
  const model = new Model();
  for (const [state, expression] of [
    ['listening', 'attentive'], ['transcribing', 'pondering'],
    ['thinking', 'pondering'], ['working', 'focused'], ['speaking', 'engaged'],
    ['completed', 'happy'], ['error', 'concerned'],
    ['needs_input', 'curious'], ['awaiting_approval', 'curious'], ['cancelled', 'soft-close'],
  ]) {
    model.setState(state);
    advance(model, .45, {reduced: true});
    assert.equal(model.state, state);
    assert.equal(model.expression, expression);
  }
  model.setState('thinking');
  advance(model, .5, {reduced: true});
  assert.ok(model.right.height > model.left.height + .09, 'thinking should be visibly asymmetric');
  model.setState('unexpected-status');
  advance(model, .5);
  assert.equal(model.state, 'idle');
  assert.equal(model.expression, 'relaxed');
});

test('repeated terminal updates cannot restart completed/cancelled animations', () => {
  for (const [state, initial, duration] of [['completed', 'happy', 3.5], ['cancelled', 'soft-close', 1.15]]) {
    const model = new Model();
    model.setState(state);
    model.update(.01);
    assert.equal(model.expression, initial);
    const entered = model.entered;
    for (let i = 0; i < Math.ceil((duration + .3) * 60); i++) {
      model.setState(state);
      model.update(1 / 60);
    }
    assert.equal(model.entered, entered);
    assert.equal(model.expression, 'relaxed');
    model.setState('speaking');
    advance(model, .2);
    model.setState(state);
    model.update(.01);
    assert.equal(model.expression, initial, 'a genuine new transition should animate again');
  }
});

test('press temporarily takes priority and release restores ongoing work', () => {
  const model = new Model();
  model.setState('thinking');
  advance(model, .5);
  advance(model, 1, {pressed: true});
  assert.equal(model.expression, 'attentive');
  assert.equal(model.state, 'thinking', 'touch feedback must not overwrite task state');
  close(model.left.height, .51);
  model.update(1 / 60, {pressed: false});
  assert.equal(model.expression, 'pondering');
  advance(model, .5);
  assert.ok(model.right.height > model.left.height + .09);
});

test('tap expressions vary, expire and yield immediately to voice/work', () => {
  const model = new Model();
  for (const expression of ['happy', 'wink', 'love']) {
    model.cheer();
    advance(model, .8, {reduced: true});
    assert.equal(model.expression, expression);
    if (expression === 'love') assert.ok(model.left.heart > .99 && model.right.heart > .99);
  }
  advance(model, 3, {reduced: true});
  assert.equal(model.expression, 'relaxed');
  assert.equal(model.gesture, null);
  assert.ok(model.left.heart < .001);
  for (const state of ['listening', 'transcribing', 'working', 'speaking']) {
    model.setState('idle');
    model.cheer();
    model.setState(state);
    model.update(.02);
    assert.equal(model.gesture, null);
    assert.notEqual(model.expression, 'happy');
    assert.notEqual(model.expression, 'wink');
    assert.notEqual(model.expression, 'love');
  }
});

test('reduced motion suppresses blink/pulse loops but preserves semantic expressions', () => {
  const model = new Model();
  model.setState('speaking');
  advance(model, 1, {reduced: true});
  const heights = [model.left.height, model.right.height];
  for (let i = 0; i < 1800; i++) {
    model.update(1 / 60, {reduced: true});
    assert.equal(model.left.open, 1);
    assert.equal(model.right.open, 1);
    close(model.left.height, heights[0]);
    close(model.right.height, heights[1]);
  }
  assert.equal(model.expression, 'engaged');
  model.setState('working');
  advance(model, 1, {reduced: true});
  close(model.gaze.x, 0);
  model.setState('idle');
  model.cheer();
  advance(model, .5, {reduced: true});
  assert.equal(model.expression, 'happy');
});

test('normal blinking closes briefly and always reopens', () => {
  const model = new Model();
  let closures = 0, continuousClosed = 0, longestClosed = 0, lastClosed = false;
  for (let i = 0; i < 3600; i++) {
    model.update(1 / 120);
    const closed = model.left.open < .9;
    if (closed && !lastClosed) closures++;
    continuousClosed = closed ? continuousClosed + 1 / 120 : 0;
    longestClosed = Math.max(longestClosed, continuousClosed);
    lastClosed = closed;
    assert.ok(model.left.open >= .059 && model.left.open <= 1);
    assert.equal(model.left.open, model.right.open);
  }
  assert.ok(closures >= 4);
  assert.ok(longestClosed < .3, `blink stayed closed for ${longestClosed}s`);
});

test('gaze follows a nearby moving pointer and releases stale/far interest', () => {
  const model = new Model();
  advance(model, 1, {pointerX: .8, pointerY: .5, pointerAge: 0, reduced: true});
  assert.ok(model.gaze.x > .05 && model.gaze.y > .02);
  assert.equal(model.expression, 'curious');
  advance(model, 1, {pointerX: -.8, pointerY: -.5, pointerAge: 0, reduced: true});
  assert.ok(model.gaze.x < -.05 && model.gaze.y < -.02);
  advance(model, 1, {pointerX: -100, pointerY: 100, pointerAge: 0, reduced: true});
  close(model.gaze.x, 0);
  close(model.gaze.y, 0);
  advance(model, 1, {pointerX: .8, pointerY: .5, pointerAge: 99, reduced: true});
  assert.equal(model.expression, 'relaxed');
  close(model.gaze.x, 0);
});

test('quiet idle becomes sleepy and user interest wakes it', () => {
  const model = new Model();
  advance(model, 25, {reduced: true});
  assert.equal(model.expression, 'sleepy');
  model.update(.02, {pointerX: .3, pointerAge: 0});
  assert.equal(model.expression, 'curious');
  model.update(.02, {pressed: true});
  assert.equal(model.expression, 'attentive');
});

test('interrupted frames and 40,000 mixed updates remain finite and within display bounds', () => {
  const model = new Model();
  const initialTime = model.time;
  model.update(-2);
  assert.equal(model.time, initialTime);
  model.update(1000);
  close(model.time, .08);
  let seed = 91;
  const random = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 4294967296);
  for (let i = 0; i < 40000; i++) {
    if (i % 41 === 0) model.setState(states[Math.floor(random() * states.length)]);
    if (i % 101 === 0) model.cheer();
    model.update(i % 67 === 0 ? 2 : random() * .08, {
      pointerX: random() * 20 - 10, pointerY: random() * 20 - 10,
      pointerAge: random() * 8, pressed: i % 43 < 7, reduced: i % 97 < 20,
    });
    for (const eye of [model.left, model.right]) {
      for (const value of Object.values(eye)) assert.ok(Number.isFinite(value));
      assert.ok(eye.width > 0 && eye.width < .4);
      assert.ok(eye.height > 0 && eye.height < .6);
      assert.ok(eye.open >= .059 && eye.open <= 1);
      assert.ok(eye.heart >= 0 && eye.heart <= 1);
      assert.ok(Math.abs(eye.x) < .13 && Math.abs(eye.y) < .15);
    }
  }
});
