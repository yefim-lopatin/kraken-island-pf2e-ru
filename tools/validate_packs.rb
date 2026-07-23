#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
REGISTRY = JSON.parse(ROOT.join("data", "document-registry.json").read)
RECIPE = JSON.parse(ROOT.join("data", "act-one-slice.json").read)
MANIFEST = JSON.parse(ROOT.join("module.json").read)

node = ENV.fetch("NODE", "node")
foundry_app = Pathname.new(ENV.fetch("FOUNDRY_APP", "/Applications/Foundry Virtual Tabletop.app/Contents/Resources/app"))
classic_level = Pathname.new(ENV.fetch("CLASSIC_LEVEL", foundry_app.join("node_modules", "classic-level", "index.js").to_s))
pf2e_data = Pathname.new(ENV.fetch("PF2E_DATA", Pathname.new(Dir.home).join("Library", "Application Support", "FoundryVTT", "Data", "systems", "pf2e").to_s))

errors = []
errors << "нет classic-level #{classic_level}" unless classic_level.file?
errors << "нет PF2e system.json" unless pf2e_data.join("system.json").file?

script = <<~'JAVASCRIPT'
  import fs from "node:fs";
  import os from "node:os";
  import path from "node:path";
  import {pathToFileURL} from "node:url";

  const [root, classicLevelPath, pf2eRoot] = process.argv.slice(1);
  const {ClassicLevel} = await import(pathToFileURL(classicLevelPath));
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "module.json"), "utf8"));
  const output = {packs: {}, systemUuids: {}};
  const foundUuids = new Set();
  function collectUuids(value) {
    if (typeof value === "string") {
      for (const match of value.matchAll(/Compendium\.pf2e\.[A-Za-z0-9_-]+\.(?:Actor|Item|JournalEntry|Scene|RollTable)\.[A-Za-z0-9]{16}/g)) foundUuids.add(match[0]);
    } else if (Array.isArray(value)) value.forEach(collectUuids);
    else if (value && typeof value === "object") Object.values(value).forEach(collectUuids);
  }
  for (const pack of manifest.packs) {
    const db = new ClassicLevel(path.join(root, pack.path), {keyEncoding: "utf8", valueEncoding: "json", readOnly: true});
    await db.open();
    const rows = [];
    for await (const [key, value] of db.iterator()) rows.push({key, value});
    await db.close();
    output.packs[pack.name] = rows;
    rows.forEach(row => collectUuids(row.value));
  }
  const systemManifest = JSON.parse(fs.readFileSync(path.join(pf2eRoot, "system.json"), "utf8"));
  const systemPacks = new Map(systemManifest.packs.map(pack => [pack.name, pack.path]));
  const collectionByType = {Actor: "actors", Item: "items", JournalEntry: "journal", Scene: "scenes", RollTable: "tables"};
  const openedSystemPacks = new Map();
  const snapshots = [];
  async function openSystemPack(packName) {
    if (openedSystemPacks.has(packName)) return openedSystemPacks.get(packName);
    const source = path.join(pf2eRoot, systemPacks.get(packName));
    let db = new ClassicLevel(source, {keyEncoding: "utf8", valueEncoding: "json", readOnly: true});
    try { await db.open(); }
    catch (error) {
      try { await db.close(); } catch {}
      if (error?.cause?.code !== "LEVEL_LOCKED" && error?.code !== "LEVEL_DATABASE_NOT_OPEN") throw error;
      const snapshotRoot = fs.mkdtempSync(path.join(os.tmpdir(), "kraken-pf2e-pack-"));
      const snapshot = path.join(snapshotRoot, "pack");
      fs.cpSync(source, snapshot, {recursive: true});
      fs.rmSync(path.join(snapshot, "LOCK"), {force: true});
      snapshots.push(snapshotRoot);
      db = new ClassicLevel(snapshot, {keyEncoding: "utf8", valueEncoding: "json", readOnly: true});
      await db.open();
    }
    openedSystemPacks.set(packName, db);
    return db;
  }
  for (const uuid of foundUuids) {
    const match = uuid.match(/^Compendium\.pf2e\.([A-Za-z0-9_-]+)\.(Actor|Item|JournalEntry|Scene|RollTable)\.([A-Za-z0-9]{16})$/);
    if (!match || !systemPacks.has(match[1])) { output.systemUuids[uuid] = false; continue; }
    const db = await openSystemPack(match[1]);
    try { await db.get(`!${collectionByType[match[2]]}!${match[3]}`); output.systemUuids[uuid] = true; }
    catch { output.systemUuids[uuid] = false; }
  }
  for (const db of openedSystemPacks.values()) await db.close();
  for (const snapshot of snapshots) fs.rmSync(snapshot, {recursive: true, force: true});
  process.stdout.write(JSON.stringify(output));
JAVASCRIPT

unless errors.any?
  stdout, stderr, status = Open3.capture3(node, "--input-type=module", "-e", script, ROOT.to_s, classic_level.to_s, pf2e_data.to_s)
  errors << "не удалось прочитать LevelDB: #{stderr.strip}" unless status.success?
  inspection = status.success? ? JSON.parse(stdout) : {"packs" => {}, "systemUuids" => {}}
  packs = inspection["packs"]
end

def walk(value, path = [], &block)
  case value
  when Hash
    value.each { |key, nested| walk(nested, path + [key], &block) }
  when Array
    value.each_with_index { |nested, index| walk(nested, path + [index], &block) }
  else
    yield value, path
  end
end

if errors.empty?
  expected_by_pack = REGISTRY.fetch("documents").select { |doc| doc["status"] == "implemented" }.group_by { |doc| doc["pack"] }
  collection_by_type = {"Actor" => "actors", "Item" => "items", "JournalEntry" => "journal", "Scene" => "scenes", "RollTable" => "tables"}
  top_documents = {}
  all_values = []

  MANIFEST.fetch("packs").each do |pack|
    rows = packs.fetch(pack["name"], [])
    collection = collection_by_type.fetch(pack["type"])
    top_rows = rows.select { |row| row["key"].match?(/\A!#{Regexp.escape(collection)}![^.]+\z/) }
    actual_ids = top_rows.map { |row| row.dig("value", "_id") }.sort
    expected_ids = expected_by_pack.fetch(pack["name"], []).map { |doc| doc["_id"] }.sort
    errors << "pack #{pack['name']}: top-level ID не совпадают с реестром" unless actual_ids == expected_ids
    top_rows.each { |row| top_documents[[pack["name"], row.dig("value", "_id")]] = row["value"] }
    rows.each { |row| all_values << [pack["name"], row["key"], row["value"]] }
  end

  actor_rows = packs.fetch("act-one-actors", []).select { |row| row["key"].match?(/\A!actors![^.]+\z/) }
  errors << "Actor pack: ожидалось 10 документов" unless actor_rows.length == 10
  errors << "Actor pack: ожидалось 9 npc" unless actor_rows.count { |row| row.dig("value", "type") == "npc" } == 9
  errors << "Actor pack: ожидалась одна hazard" unless actor_rows.count { |row| row.dig("value", "type") == "hazard" } == 1
  actor_rows.each do |row|
    actor = row["value"]
    errors << "Actor #{actor['_id']}: нет PF2e system" unless actor["system"].is_a?(Hash)
    errors << "Actor #{actor['_id']}: битая ссылка на папку исходного pack" unless actor["folder"].nil?
    Array(actor["items"]).each do |item_id|
      key = "!actors.items!#{actor['_id']}.#{item_id}"
      errors << "Actor #{actor['_id']}: отсутствует embedded Item #{item_id}" unless packs["act-one-actors"].any? { |candidate| candidate["key"] == key }
    end
  end

  hazard = actor_rows.find { |row| row.dig("value", "type") == "hazard" }&.fetch("value")
  errors << "haunt: неверный уровень" unless hazard&.dig("system", "details", "level", "value") == 2
  errors << "haunt: должна быть комплексной" unless hazard&.dig("system", "details", "isComplex") == true
  errors << "haunt: отсутствует признак haunt" unless Array(hazard&.dig("system", "traits", "value")).include?("haunt")

  journal = top_documents[["act-one-journal", "Act1SaltGate0001"]]
  errors << "JournalEntry: ожидалось 7 страниц" unless Array(journal&.fetch("pages", nil)).length == 7
  Array(journal&.fetch("pages", nil)).each do |page_id|
    key = "!journal.pages!Act1SaltGate0001.#{page_id}"
    errors << "JournalEntry: отсутствует страница #{page_id}" unless packs["act-one-journal"].any? { |row| row["key"] == key }
  end

  scene_rows = packs.fetch("act-one-scenes", []).select { |row| row["key"].match?(/\A!scenes![^.]+\z/) }
  errors << "Scene pack: ожидалось 4 сцены" unless scene_rows.length == 4
  scene_rows.each do |row|
    scene = row["value"]
    %w[grid fog environment transition levels].each do |field|
      errors << "Scene #{scene['_id']}: нет поля v14 #{field}" unless scene.key?(field)
    end
    Array(scene["levels"]).each do |level_id|
      key = "!scenes.levels!#{scene['_id']}.#{level_id}"
      errors << "Scene #{scene['_id']}: отсутствует Level #{level_id}" unless packs["act-one-scenes"].any? { |candidate| candidate["key"] == key }
    end
  end

  table = top_documents[["act-one-rumors", "AperturaRumor001"]]
  errors << "RollTable: формула должна быть 1d6" unless table&.fetch("formula", nil) == "1d6"
  errors << "RollTable: ожидалось 6 результатов" unless Array(table&.fetch("results", nil)).length == 6

  uuids = []
  all_values.each do |pack_name, key, value|
    walk(value) do |leaf, leaf_path|
      next unless leaf.is_a?(String)
      label = "#{pack_name}:#{key}:#{leaf_path.join('.')}"
      errors << "внешний или абсолютный путь: #{label}" if leaf.match?(%r{(?:file://|/Users/|iCloud~|^[A-Za-z]:\\|https?://)})
      errors << "остаточная механика D&D 5e: #{label}" if leaf.match?(/(?:dnd5e|d&d\s*5e|challenge rating|hit dice)/i)
      errors << "ссылка на world-документ: #{label}" if leaf.match?(/(?:@UUID\[world\.|\bworld\.[A-Za-z])/)
      uuids.concat(leaf.scan(/Compendium\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.(?:Actor|Item|JournalEntry|Scene|RollTable)\.[A-Za-z0-9]{16}/))
    end
  end

  uuids.uniq.each do |uuid|
    match = uuid.match(/\ACompendium\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.(Actor|Item|JournalEntry|Scene|RollTable)\.([A-Za-z0-9]{16})\z/)
    next errors << "неверный UUID #{uuid}" unless match
    module_id, pack_name, type, id = match.captures
    if module_id == RECIPE["moduleId"]
      errors << "битый внутримодульный UUID #{uuid}" unless top_documents.key?([pack_name, id])
    elsif module_id != "pf2e"
      errors << "неразрешённый внешний UUID #{uuid}"
    end
  end

  required = RECIPE.fetch("requiredSystemUuids")
  missing_required = required - uuids.uniq
  errors << "не использованы подтверждённые UUID: #{missing_required.join(', ')}" unless missing_required.empty?
  broken_system = inspection.fetch("systemUuids", {}).select { |_uuid, exists| !exists }.keys
  errors << "битые UUID PF2e: #{broken_system.join(', ')}" unless broken_system.empty?

  manifest_packs = MANIFEST.fetch("packs").to_h { |pack| [pack["name"], pack] }
  REGISTRY.fetch("documents").select { |doc| doc["status"] == "implemented" }.each do |doc|
    pack = manifest_packs[doc["pack"]]
    errors << "реестр: неизвестный pack #{doc['pack']}" unless pack
    errors << "реестр: отсутствует документ #{doc['_id']} в #{doc['pack']}" unless top_documents.key?([doc["pack"], doc["_id"]])
  end
end

if errors.empty?
  puts "ПРОВЕРКА PACK A — LEVELDB V14 И 18 ДОКУМЕНТОВ: ПРОЙДЕНА"
  puts "ПРОВЕРКА PACK B — PF2E 8.3.0, HAUNT И EMBEDDED DOCUMENTS: ПРОЙДЕНА"
  puts "ПРОВЕРКА PACK C — UUID, ПУТИ И ОТСУТСТВИЕ D&D 5E: ПРОЙДЕНА"
  exit 0
end

warn "ПРОВЕРКА PACK НЕ ПРОЙДЕНА:"
errors.uniq.each { |error| warn "- #{error}" }
exit 1
