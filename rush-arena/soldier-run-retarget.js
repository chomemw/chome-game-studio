// Shared Rush Arena locomotion retargeter.
// Uses the proven Soldier.glb Run clip as the motion source and retargets it
// onto the more human-looking MakeHuman/MPFB runner rigs.
let soldierRunSourcePromise=null;

async function getSoldierRunSource(){
  if(!soldierRunSourcePromise){
    soldierRunSourcePromise=(async()=>{
      const [{canonicalizeGLBBones,retargetClipToObject},{GLTFLoader}]=await Promise.all([
        import('https://esm.sh/@three-ws/retarget@0.1.2?deps=three@0.160.0'),
        import('https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/loaders/GLTFLoader.js')
      ]);
      const response=await fetch('https://raw.githubusercontent.com/mrdoob/three.js/r160/examples/models/gltf/Soldier.glb');
      if(!response.ok)throw new Error('Soldier animation source failed to download: '+response.status);
      const canonical=canonicalizeGLBBones(await response.arrayBuffer());
      const loader=new GLTFLoader();
      const donor=await loader.parseAsync(canonical.buffer,'');
      const runClip=(donor.animations||[]).find(clip=>/run/i.test(clip.name));
      if(!runClip)throw new Error('Soldier Run animation clip was not found');
      return {runClip,retargetClipToObject};
    })();
  }
  return soldierRunSourcePromise;
}

export async function attachSoldierRunAnimation(targetModel,mixer,THREE){
  const {runClip,retargetClipToObject}=await getSoldierRunSource();
  targetModel.updateMatrixWorld(true);
  const result=retargetClipToObject(runClip,targetModel);
  if(!result.clip)throw new Error('Soldier run could not map to this character rig ('+Math.round((result.coverage||0)*100)+'% bone coverage)');
  const coverage=Number(result.coverage)||0;
  if(coverage<0.55)throw new Error('Soldier run retarget rejected: only '+Math.round(coverage*100)+'% bone coverage; keeping the character\'s native animation instead.');
  const action=mixer.clipAction(result.clip);
  action.enabled=true;
  action.setEffectiveTimeScale(1);
  action.setEffectiveWeight(1);
  action.setLoop(THREE.LoopRepeat,Infinity);
  return {action,coverage:result.coverage,matched:result.matched,total:result.total};
}
