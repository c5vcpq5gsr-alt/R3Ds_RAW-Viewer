#!/usr/bin/env node

const fs = require("fs");

const [outputPath, ...inputPaths] = process.argv.slice(2);
const types = ["icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"];

if (!outputPath || inputPaths.length !== types.length) {
  console.error("usage: create_icns.cjs <output.icns> <16.png> <32.png> <64.png> <128.png> <256.png> <512.png> <1024.png>");
  process.exit(2);
}

const elements = types.map((type, index) => {
  const image = fs.readFileSync(inputPaths[index]);
  const header = Buffer.alloc(8);
  header.write(type, 0, 4, "ascii");
  header.writeUInt32BE(image.length + header.length, 4);
  return Buffer.concat([header, image]);
});

const body = Buffer.concat(elements);
const header = Buffer.alloc(8);
header.write("icns", 0, 4, "ascii");
header.writeUInt32BE(body.length + header.length, 4);
fs.writeFileSync(outputPath, Buffer.concat([header, body]));
