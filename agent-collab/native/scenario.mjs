export const plan = `在临时目录实现 clamp(value, min, max)，使用 ESM 导出。业务要求：三个参数均须为有限 number，否则抛 TypeError；min > max 时抛 RangeError；值小于下界返回下界，大于上界返回上界，范围内原样返回。当前方案只写 Math.min(Math.max(value, min), max)。请交叉 review 这个方案的遗漏与必要测试，禁止修改文件。给出可以独立执行的修订方案。`;

export const fixtureTests = `import test from 'node:test';
import assert from 'node:assert/strict';
import {clamp} from './clamp.mjs';
test('boundaries and interior',()=>{assert.equal(clamp(-2,0,10),0);assert.equal(clamp(12,0,10),10);assert.equal(clamp(7,0,10),7);assert.equal(clamp(0,0,10),0);assert.equal(clamp(10,0,10),10);assert.equal(clamp(2,2,2),2);});
test('rejects nonfinite and nonnumber arguments',()=>{for(const bad of [NaN,Infinity,-Infinity,'2',null,undefined]){assert.throws(()=>clamp(bad,0,10),TypeError);assert.throws(()=>clamp(2,bad,10),TypeError);assert.throws(()=>clamp(2,0,bad),TypeError);}});
test('rejects reversed bounds',()=>assert.throws(()=>clamp(2,10,0),RangeError));
`;

export function confirmation(review) {
  return `测试确认输入：按刚才经过复核的以下修订方案交接 Codex 编码。原始要求：${plan}\n复核原文：${review}\n只创建 clamp.mjs；不得修改 clamp.test.mjs。完成后执行 node --test clamp.test.mjs，并报告实际结果。本确认仅用于隔离测试工程，不授权部署或发布。`;
}
