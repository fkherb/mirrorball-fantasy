import assert from 'node:assert/strict';
import { judgeOrderFor, sortJudgeScores } from '../judge-panel.js';
import { danceCard, danceDetail, judgePortraitFor, judgeMemberFor } from '../postdraft-view.js';

const week = { number: 5, guest_judge_name: 'Joe Buck',
  judge_order: ['Carrie Ann','Derek','Joe Buck','Bruno'],
  guest_judge_image_path: 'Images/Cast Thumbnails/Joe Buck.webp',
  guest_judge_avatar_frame: { x:54, y:5, zoom:1.7 } };
const scores = [{judge_name:'Bruno',score:10},{judge_name:'Joe Buck',score:9},
  {judge_name:'Derek',score:8},{judge_name:'Carrie Ann',score:7}];
assert.deepEqual(judgeOrderFor(week),week.judge_order);
assert.deepEqual(judgeOrderFor({}),['Carrie Ann','Derek','Bruno']);
assert.deepEqual(judgeOrderFor({...week,judge_order:['Joe Buck','Joe Buck']}),['Carrie Ann','Derek','Bruno','Joe Buck']);
assert.deepEqual(sortJudgeScores(scores,week).map(s=>s.score),[7,8,9,10]);
assert.equal(scores[0].judge_name,'Bruno','Sorting must not mutate cached data.');
assert.equal(judgeMemberFor('Joe Buck',[]),null);
assert.match(judgePortraitFor('Joe Buck','../',week),/^\.\.\/Images\/Cast Thumbnails\/Joe Buck.webp\?/);
assert.equal(judgePortraitFor('Joe Buck'),'', 'Portrait must be scoped to the guest week.');
const props = {id:'preview',kind:'competitive',title:'Test couple',scores,week,
  guestJudge:true,complete:true,scoreImage:n=>`Images/Judges Scores/${n}.png`,
  judgePhoto:name=>judgePortraitFor(name,'',week),judgeMember:()=>null,
  teams:[],castRows:[]};
for(const html of [danceCard(props),danceDetail(props)]) {
  const positions=week.judge_order.map(name=>html.indexOf(`aria-label="${name}:`));
  assert.ok(positions.every((p,i)=>p>=0 && (!i || p>positions[i-1])),'Cards and details must render Wikipedia panel order.');
  assert.match(html,/Joe Buck.webp/);
  assert.match(html,/width:170%;height:170%/,'Guest gets its own face crop.');
}
assert.match(danceCard(props),/--ring-value:85%/,'34 out of 40 is an 85% donut.');
console.log('Four-judge card/detail order, guest portrait crop without a cast record, and 40-point donut verified.');
