import assert from 'node:assert/strict';
import { judgeOrderFor, sortJudgeScores, configureRegularJudges, regularJudgeNames, loadRegularJudges } from '../judge-panel.js';
import { danceCard, danceDetail, judgePortraitFor, judgeMemberFor } from '../postdraft-view.js';

const week = { number: 5, guest_judge_name: 'Joe Buck',
  judge_order: ['Carrie Ann','Derek','Joe Buck','Bruno'],
  guest_judge_image_path: 'Images/People/Joe Buck/portrait.webp?v=2',
  guest_judge_avatar_frame: {} };
const scores = [{judge_name:'Bruno',score:10},{judge_name:'Joe Buck',score:9},
  {judge_name:'Derek',score:8},{judge_name:'Carrie Ann',score:7}];
assert.deepEqual(judgeOrderFor(week),week.judge_order);
assert.deepEqual(judgeOrderFor({}),['Carrie Ann','Derek','Bruno']);
assert.deepEqual(judgeOrderFor({...week,judge_order:['Joe Buck','Joe Buck']}),['Carrie Ann','Derek','Bruno','Joe Buck']);
assert.deepEqual(sortJudgeScores(scores,week).map(s=>s.score),[7,8,9,10]);
assert.equal(scores[0].judge_name,'Bruno','Sorting must not mutate cached data.');
assert.ok(configureRegularJudges(['Bruno','Carrie Ann','Derek']));
assert.deepEqual(judgeOrderFor({}),['Bruno','Carrie Ann','Derek'],'Fallback order comes from configuration.');
assert.deepEqual(judgeOrderFor(week),week.judge_order,'Explicit weekly Wikipedia order remains authoritative.');
assert.equal(configureRegularJudges(['Judge',' judge ']),false);
assert.equal(configureRegularJudges([]),false);
assert.equal(configureRegularJudges([null]),false);
const copy = regularJudgeNames(); copy.reverse();
assert.deepEqual(regularJudgeNames(),['Bruno','Carrie Ann','Derek']);
let configReads = 0;
const db = {from(table) { assert.equal(table,'app_config'); configReads++; return {
  select:() => ({eq:(key,value) => {assert.equal(key,'key');assert.equal(value,'regular_judges');
    return {single:async()=>({data:{value:['Carrie Ann','Derek','Bruno']}})};}}),
};}};
await Promise.all([loadRegularJudges(db),loadRegularJudges(db)]);
assert.equal(configReads,1,'Concurrent renders share a config request.');
assert.deepEqual(regularJudgeNames(),['Carrie Ann','Derek','Bruno']);
assert.equal(judgeMemberFor('Joe Buck',[]),null);
assert.equal(judgePortraitFor('Joe Buck','../',week),'../Images/People/Joe Buck/profile.webp?v=2');
assert.equal(judgePortraitFor('Joe Buck'),'', 'Portrait must be scoped to the guest week.');
const props = {id:'preview',kind:'competitive',title:'Test couple',scores,week,
  guestJudge:true,complete:true,scoreImage:n=>`Images/Judges Scores/${n}.png`,
  judgePhoto:name=>judgePortraitFor(name,'',week),judgeMember:()=>null,
  teams:[],castRows:[]};
for(const html of [danceCard(props),danceDetail(props)]) {
  const positions=week.judge_order.map(name=>html.indexOf(`aria-label="${name}:`));
  assert.ok(positions.every((p,i)=>p>=0 && (!i || p>positions[i-1])),'Cards and details must render Wikipedia panel order.');
  assert.match(html,/Images\/People\/Joe Buck\/profile.webp\?v=2/,'Guest uses their rendered profile picture.');
}
assert.match(danceCard(props),/--ring-value:85%/,'34 out of 40 is an 85% donut.');
console.log('Four-judge card/detail order, guest profile picture without a cast record, and 40-point donut verified.');
