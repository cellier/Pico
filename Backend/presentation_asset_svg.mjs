import {createRequire} from 'node:module';
import path from 'node:path';
const [modules,input,output]=process.argv.slice(2);
const require=createRequire(path.join(modules,'package.json'));
const sharp=require('sharp');
await sharp(input,{limitInputPixels:40000000,density:144}).resize({width:1600,height:1600,fit:'inside',withoutEnlargement:true}).png().toFile(output);
