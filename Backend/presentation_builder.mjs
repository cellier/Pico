import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const [configPath,specPath,outDir]=process.argv.slice(2);
const runtime=JSON.parse(await fs.readFile(configPath,'utf8'));
process.env.RUNTIME_NODE_MODULES=runtime.modules;
process.env.RUNTIME_NODE=runtime.node;
process.env.RUNTIME_PYTHON=runtime.python;
const require=createRequire(path.join(runtime.modules,'package.json'));
const {Presentation,PresentationFile}=await import(pathToFileURL(require.resolve('@oai/artifact-tool')).href);
const spec=JSON.parse(await fs.readFile(specPath,'utf8'));
const themes={executive:{ink:'#182B45',accent:'#225FCC',paper:'#FFFFFF',muted:'#596778'},editorial:{ink:'#302634',accent:'#993F58',paper:'#FFFFFF',muted:'#665E69'},scientific:{ink:'#123B35',accent:'#087E79',paper:'#FFFFFF',muted:'#496D68'}};
const ds=spec.resolved_style?.design;
const theme={...themes[spec.theme??'executive'],...(ds?{ink:ds.ink,accent:ds.accent,paper:ds.paper,muted:ds.muted}:{}),...spec.colors};
const composition=ds?.composition??'classic';
const contrast=c=>{const v=c.slice(1).match(/../g).map(x=>parseInt(x,16));return v[0]*.299+v[1]*.587+v[2]*.114>150?'#151515':'#FFFFFF';};
const luminance=c=>c.slice(1).match(/../g).map(x=>parseInt(x,16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4).reduce((a,v,i)=>a+v*[.2126,.7152,.0722][i],0);
const readableAccent=(Math.max(luminance(theme.accent),luminance(theme.paper))+.05)/(Math.min(luminance(theme.accent),luminance(theme.paper))+.05)>=4.5?theme.accent:theme.ink;
let isCover=false;let coverPhoto=false;
function frame(x,y,w,h){if(ds&&composition==='split'&&!isCover&&y>=200&&y<660)return {left:470+(x-72)*.64,top:y,width:w*.64,height:h};return {left:x,top:y,width:w,height:h};}
const font=spec.font??(/[\u3400-\u9FFF]/u.test(JSON.stringify(spec.slides))?'PingFang SC':'Arial');
const p=Presentation.create({slideSize:{width:1280,height:720}});
const boxes=[];
function text(slide,value,x,y,w,h,size=28,color=theme.ink,bold=false){
 if(!value)return;
 if(!isCover&&color===theme.accent)color=readableAccent;
 const shape=slide.shapes.add({geometry:'textbox',position:frame(x,y,w,h),fill:'none',line:{fill:'none',width:0}});
 const heading=bold&&((isCover&&y===155)||(!isCover&&y===54));
 let face=font;
 if(heading&&ds&&!/[\u3400-\u9FFF]/u.test(String(value)))face=ds.heading_family==='serif'?'Georgia':ds.heading_family==='mono'?'Courier New':font;
 if(ds){if(heading)size=isCover?ds.cover_size:ds.title_size;else if(size>=24&&size<=32)size=ds.body_size;}
 if(ds&&composition==='stage'&&!coverPhoto&&(heading||isCover||size>=40)&&w>300){shape.position={left:ds.margin,top:y,width:1280-2*ds.margin,height:h};}
 if(ds&&heading&&!isCover){shape.position=composition==='split'?{left:ds.margin,top:145,width:340,height:410}:{left:ds.margin,top:composition==='editorial'?38:54,width:1280-ds.margin*2,height:135};}
 shape.text=String(value);shape.text.style={fontSize:size,typeface:face,color,bold,alignment:(heading||isCover||size>=40)?(ds?.heading_align??(composition==='stage'?'center':'left')):'left',wrap:'square',autoFit:'none',insets:0,verticalAlignment:'top'};
 boxes.push({slide:p.slides.items.length,text:String(value),x,y,w,h,size});return shape;
}
for(const [index,s] of spec.slides.entries()){
 const slide=p.slides.add();const dark=['cover','closing'].includes(s.layout);isCover=dark;coverPhoto=dark&&!!s.image;
 const background=ds?(dark&&ds.cover_invert&&contrast(theme.paper)==='#151515'?theme.ink:theme.paper):(dark?theme.ink:theme.paper);slide.background.fill=background;
 const ink=dark?contrast(background):theme.ink;const muted=dark?(ink==='#FFFFFF'?'#D8DFE8':theme.muted):theme.muted;
 if(ds?.accent_rule&&ds.accent_rule!=='none'){slide.shapes.add({geometry:'rect',position:{left:ds.heading_align==='center'&&ds.accent_rule==='short'?592:ds.margin,top:dark?120:184,width:ds.accent_rule==='full'?1280-2*ds.margin:96,height:ds.accent_rule==='full'?2:5},fill:theme.accent,line:{fill:'none',width:0}});}
 if(dark&&s.image){slide.images.add({blob:new Uint8Array(await fs.readFile(s.image.path)),contentType:'image/png',alt:s.image.alt??s.title,fit:s.image.fit??'cover',position:{left:740,top:0,width:540,height:720}});}
 if(dark){
  text(slide,s.title,72,155,s.image?600:1096,200,64,ink,true);
  text(slide,s.body,76,398,s.image?590:990,128,30,muted);
  if(s.label)text(slide,s.label,76,82,1040,40,22,muted);
 }else{
  text(slide,s.title,72,54,1120,118,44,ink,true);
  switch(s.layout){
  case 'statement':
   text(slide,s.body,76,228,1070,310,46,ink);break;
  case 'comparison':
   for(const [i,c] of s.columns.entries()){
    text(slide,c.title,76+i*586,204,530,76,32,theme.accent,true);
    text(slide,c.body,76+i*586,304,510,292,28,ink);
   }break;
  case 'metrics':{
   const w=1128/s.metrics.length;
   for(const [i,m] of s.metrics.entries()){
    text(slide,m.value,76+i*w,240,w-36,125,64,theme.accent,true);
    text(slide,m.label,76+i*w,388,w-36,135,28,ink);
   }break;}
  case 'chart':{
   const c=s.chart;
   const chart=slide.charts.add(c.type??'bar',{position:frame(76,208,1120,390),chartFill:theme.paper,plotAreaFill:theme.paper,categories:c.categories,series:c.series.map((v,i)=>({...v,fill:[theme.accent,theme.ink,'#8495AA'][i%3]})),hasLegend:c.series.length>1,legend:{textStyle:{fontSize:22,fill:theme.ink}},dataLabels:{showValue:c.categories.length<=8,position:c.type==='line'?'above':'outEnd',textStyle:{fontSize:22,fill:theme.ink}},xAxis:{textStyle:{fontSize:22,fill:theme.ink}},yAxis:{title:{text:c.unit??(c.series.length===1?c.series[0].name:''),textStyle:{fontSize:22,fill:theme.ink}},textStyle:{fontSize:20,fill:theme.ink},majorGridlines:{fill:ds?.chart_grid===false?theme.paper:(contrast(theme.paper)==='#FFFFFF'?'#444444':'#E4E8ED'),width:ds?.chart_grid===false?0:1,style:'solid'}}});
   const {applyPresentationChartFont}=await import(pathToFileURL(path.join(runtime.skill,'container_tools/artifact_tool_utils.mjs')).href);
   applyPresentationChartFont(chart,{fontFamily:font});
   break;}
  case 'table':{
   const rows=s.table;
   const table=slide.tables.add({rows:rows.length,columns:rows[0].length,...frame(76,210,1120,Math.min(375,rows.length*62)),values:rows});
   for(let r=0;r<rows.length;r++)for(let c=0;c<rows[r].length;c++){
    const cell=table.getCell(r,c);cell.fill=r===0?theme.accent:theme.paper;
    cell.text.style={typeface:font,fontSize:24,bold:r===0,color:r===0?contrast(theme.accent):theme.ink};
   }
   table.borders.assign({style:'solid',fill:'#D5DDE5',width:1});
   break;}
  case 'image':
   slide.images.add({blob:new Uint8Array(await fs.readFile(s.image.path)),contentType:'image/png',alt:s.image.alt??s.title,fit:s.image.fit??'contain',position:frame(630,208,570,380)});
   text(slide,s.body,76,216,490,348,30,ink);break;
  default:{
   const points=s.points??[s.body];const step=Math.min(132,390/points.length);
   for(const [i,item] of points.entries()){
    if(ds&&composition==='editorial'&&points.length>1){text(slide,String(i+1).padStart(2,'0'),76+(i%2)*734,215+Math.floor(i/2)*180,80,44,26,theme.accent,true);text(slide,item,76+(i%2)*734,265+Math.floor(i/2)*180,i%2?382:650,125,30,ink);}
    else if(ds&&composition==='technical'){text(slide,String(i+1).padStart(2,'0'),76,208+i*step,64,step-22,24,theme.accent,true);text(slide,item,164,208+i*step,1000,step-22,30,ink);}
    else text(slide,item,76,208+i*step,1090,step-22,30,ink);
   }
  }
  }
  if(s.caption)text(slide,s.caption,76,615,1080,40,19,theme.muted);
 }
 if(s.logo){slide.images.add({blob:new Uint8Array(await fs.readFile(s.logo.path)),contentType:'image/png',alt:s.logo.alt??'Brand logo',fit:'contain',position:{left:76,top:666,width:140,height:32}});}
 if(ds?.page_numbers!==false)text(slide,String(index+1).padStart(2,'0'),1160,667,40,25,16,muted);
 slide.speakerNotes.text=[s.notes??'',...(s.sources??[]).map(v=>`Source: ${v}`)].filter(Boolean).join('\n');
}
await fs.mkdir(outDir,{recursive:true});
await fs.mkdir(path.join(outDir,'validated'),{recursive:true});
const candidate=path.join(outDir,'candidate.pptx');
await (await PresentationFile.exportPptx(p)).save(candidate);
const {finalizePresentation}=await import(pathToFileURL(path.join(runtime.skill,'container_tools/artifact_tool_utils.mjs')).href);
await finalizePresentation({workspaceDir:outDir,candidatePath:candidate,finalPath:path.join(outDir,'validated/deck.pptx'),pythonExecutable:runtime.python,integrityValidatorPath:path.join(runtime.skill,'container_tools/inspect_presentation_package_integrity.py'),layoutValidatorPath:path.join(runtime.skill,'container_tools/inspect_presentation_layout_geometry.py'),layoutArgs:['--expected-slide-size-emu','12192000,6858000','--validate-heading-fit'],explicitTotalSlideCount:spec.expected_slide_count,allowChartWorkbookSnapshot:true,materializeLiteralChartWorkbooks:true,verifyArtifactToolImport:true,receiptPath:path.join(outDir,'package-validation.json')});
await fs.copyFile(path.join(outDir,'validated/deck.pptx'),path.join(outDir,'draft.pptx'));
for(const [i,slide] of p.slides.items.entries()){
 const blob=await p.export({slide,format:'png',scale:1.5});
 await fs.writeFile(path.join(outDir,`slide-${String(i+1).padStart(2,'0')}.png`),new Uint8Array(await blob.arrayBuffer()));
}
await fs.writeFile(path.join(outDir,'geometry.json'),JSON.stringify(boxes));
console.log(JSON.stringify({slides:p.slides.items.length,font,renderer:'artifact-tool'}));
