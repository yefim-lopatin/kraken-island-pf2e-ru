#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
RECIPE = ROOT.join("data", "act-one-slice.json")

node = ENV.fetch("NODE", "node")
foundry_app = Pathname.new(ENV.fetch("FOUNDRY_APP", "/Applications/Foundry Virtual Tabletop.app/Contents/Resources/app"))
classic_level = Pathname.new(ENV.fetch("CLASSIC_LEVEL", foundry_app.join("node_modules", "classic-level", "index.js").to_s))
pf2e_data = Pathname.new(ENV.fetch("PF2E_DATA", Pathname.new(Dir.home).join("Library", "Application Support", "FoundryVTT", "Data", "systems", "pf2e").to_s))
pf2e_source = Pathname.new(ENV.fetch("PF2E_SOURCE", ROOT.join("..", "..", "..", "PF2e База", "_source", "foundry-pf2e").cleanpath.to_s))

abort "Нет рецепта #{RECIPE}" unless RECIPE.file?
abort "Нет classic-level #{classic_level}" unless classic_level.file?
abort "Нет установленной PF2e #{pf2e_data}" unless pf2e_data.join("system.json").file?

script = <<~'JAVASCRIPT'
  import fs from "node:fs";
  import path from "node:path";
  import {pathToFileURL} from "node:url";

  const [root, recipePath, pf2eRoot, classicLevelPath, pf2eSource] = process.argv.slice(1);
  const {ClassicLevel} = await import(pathToFileURL(classicLevelPath));
  const recipe = JSON.parse(fs.readFileSync(recipePath, "utf8"));
  const systemManifest = JSON.parse(fs.readFileSync(path.join(pf2eRoot, "system.json"), "utf8"));
  const packPaths = new Map(systemManifest.packs.map(pack => [pack.name, pack.path]));
  const stats = source => ({
    coreVersion: recipe.coreVersion,
    systemId: recipe.systemId,
    systemVersion: recipe.systemVersion,
    compendiumSource: source ?? null
  });
  const clone = value => structuredClone(value);

  let sourceFiles;
  let sourceActors;
  function listJsonFiles(directory) {
    const found = [];
    for (const entry of fs.readdirSync(directory, {withFileTypes: true})) {
      const target = path.join(directory, entry.name);
      if (entry.isDirectory()) found.push(...listJsonFiles(target));
      else if (entry.isFile() && entry.name.endsWith(".json")) found.push(target);
    }
    return found;
  }

  function readActorSource(id) {
    const sourcePackRoot = path.join(pf2eSource, "packs", "pf2e");
    if (!fs.existsSync(sourcePackRoot)) {
      throw new Error(`Системный pack PF2e заблокирован. Закройте Foundry или задайте PF2E_SOURCE с исходниками PF2e 8.3.0: ${pf2eSource}`);
    }
    sourceFiles ??= listJsonFiles(sourcePackRoot);
    if (!sourceActors) {
      const requiredIds = new Set(recipe.actors.map(actor => actor.sourceUuid.split(".").at(-1)));
      sourceActors = new Map();
      for (const file of sourceFiles) {
        const raw = fs.readFileSync(file, "utf8");
        if (![...requiredIds].some(requiredId => raw.includes(`"_id": "${requiredId}"`))) continue;
        const document = JSON.parse(raw);
        if (requiredIds.has(document._id) && document.type === "npc") sourceActors.set(document._id, document);
        if (sourceActors.size === requiredIds.size) break;
      }
    }
    if (sourceActors.has(id)) return clone(sourceActors.get(id));
    throw new Error(`В исходном наборе PF2e 8.3.0 нет Actor ${id}`);
  }

  async function readActor(uuid) {
    const match = uuid.match(/^Compendium\.pf2e\.([a-z0-9-]+)\.Actor\.([A-Za-z0-9]{16})$/);
    if (!match) throw new Error(`Неподдерживаемый Actor UUID: ${uuid}`);
    const [, packName, id] = match;
    const relative = packPaths.get(packName);
    if (!relative) throw new Error(`В PF2e 8.3.0 нет pack ${packName}`);
    const db = new ClassicLevel(path.join(pf2eRoot, relative), {keyEncoding: "utf8", valueEncoding: "json", readOnly: true});
    try {
      await db.open();
      const actor = await db.get(`!actors!${id}`);
      const items = [];
      for (const itemId of actor.items ?? []) items.push(await db.get(`!actors.items!${id}.${itemId}`));
      await db.close();
      actor.items = items;
      return actor;
    } catch (error) {
      try { await db.close(); } catch {}
      if (error?.cause?.code !== "LEVEL_LOCKED" && error?.code !== "LEVEL_DATABASE_NOT_OPEN") throw error;
      return readActorSource(id);
    }
  }

  const localizedDescriptions = {
    eulyI60JHNUYs39w: "<p>Зомби постоянно @UUID[Compendium.pf2e.conditionitems.Item.xYTAsEpcJE1Ccni3]{замедлен 1} и не может использовать реакции.</p>",
    q1OobVjFqRsc58KI: "<p>@Localize[PF2E.NPC.Abilities.Glossary.NegativeHealing]</p>",
    Qknp3UNQSMjNTUmL: "<p>@Localize[PF2E.NPC.Abilities.Glossary.Grab]</p>",
    v90WRjELLiKF57vr: "<p><strong>Требования</strong> Зомби держит существо @UUID[Compendium.pf2e.conditionitems.Item.kWc1fhmv9LBiTuei]{схваченным} или @UUID[Compendium.pf2e.conditionitems.Item.VcDeM8A5oI6VqhbM]{сдерживаемым}.</p>",
    zMkrKhyfRWFrFfuv: "<p><strong>Эффект</strong> До начала своего следующего хода культист получает бонус состояния +2 к броскам атак и урона, но штраф состояния −2 к КБ.</p>"
  };

  const actors = [];
  for (const spec of recipe.actors) {
    const actor = await readActor(spec.sourceUuid);
    actor._id = spec._id;
    actor.name = spec.name;
    actor.folder = null;
    actor.items = actor.items.filter(item => spec.keepItemIds.includes(item._id));
    for (const item of actor.items) {
      if (spec.itemNames[item._id]) item.name = spec.itemNames[item._id];
      if (localizedDescriptions[item._id] && item.system?.description) item.system.description.value = localizedDescriptions[item._id];
      if (item.system?.selfEffect?.name === "Effect: Fanatical Frenzy") item.system.selfEffect.name = "Эффект: Фанатичное безумие";
      item._stats = stats(item._stats?.compendiumSource);
    }
    actor.system.details.publicNotes = spec.publicNotes;
    actor.system.details.privateNotes = "";
    if (actor.system.attributes?.hp?.details === "void healing") actor.system.attributes.hp.details = "исцеление пустотой";
    if (actor.system.perception?.details === "+8 to spot fish") actor.system.perception.details = "+8, чтобы заметить рыбу";
    if (actor.system.attributes?.allSaves?.value === "(Will +2 vs. higher-ranking members of the cult)") {
      actor.system.attributes.allSaves.value = "(Воля +2 против вышестоящих членов культа)";
    }
    if (actor.system.saves?.will?.saveDetail === "(or +2 vs. higher-ranking members of the cult)") {
      actor.system.saves.will.saveDetail = "(или +2 против вышестоящих членов культа)";
    }
    actor.flags = {...(actor.flags ?? {}), [recipe.moduleId]: {designId: spec.designId, sourceUuid: spec.sourceUuid}};
    actor._stats = stats(spec.sourceUuid);

    if (spec.adjustment === "weak-act-one") {
      actor.system.details.level.value = -2;
      actor.system.attributes.ac.value = 10;
      actor.system.perception.mod = -2;
      actor.system.saves.fortitude.value = 4;
      actor.system.saves.reflex.value = -2;
      actor.system.saves.will.value = 0;
      actor.system.skills.athletics.base = 5;
      for (const item of actor.items.filter(item => item.type === "melee")) {
        item.system.bonus.value = 5;
        for (const damage of Object.values(item.system.damageRolls ?? {})) {
          damage.damage = damage.damage.replace(/\+3$/, "+1");
        }
      }
    }
    actors.push(actor);
  }

  for (const hazard of recipe.hazards) {
    actors.push({
      _id: hazard._id,
      name: hazard.name,
      type: "hazard",
      img: "systems/pf2e/icons/default-icons/hazard.svg",
      items: hazard.actions.map((action, index) => ({
        _id: action._id,
        name: action.name,
        type: "action",
        img: action.img,
        sort: (index + 1) * 100000,
        system: {
          actionType: {value: action.actionType},
          actions: {value: action.actions ?? null},
          category: index === 0 ? "defensive" : "offensive",
          description: {value: action.description},
          publication: {license: "ORC", remaster: true, title: "Остров Кракена"},
          rules: [],
          slug: null,
          traits: {rarity: "common", value: ["haunt"]}
        },
        effects: [],
        _stats: stats(null)
      })),
      system: {
        attributes: {
          ac: {value: 0}, emitsSound: "encounter", hardness: 0, hasHealth: false,
          hp: {details: "", max: 0, temp: 0, tempmax: 0, value: 0},
          stealth: {details: "<p>Владение не требуется</p>", value: hazard.stealth}
        },
        creatureType: "",
        details: {
          description: hazard.description, disable: hazard.disable, isComplex: true,
          level: {value: hazard.level}, publication: {license: "ORC", remaster: true, title: "Остров Кракена"},
          reset: hazard.reset, routine: hazard.routine
        },
        saves: {
          fortitude: {saveDetail: "", value: 0}, reflex: {saveDetail: "", value: 0}, will: {saveDetail: "", value: 0}
        },
        statusEffects: [],
        traits: {rarity: "unique", size: {value: "med"}, value: ["haunt"]}
      },
      effects: [],
      flags: {[recipe.moduleId]: {designId: hazard.designId}},
      _stats: stats(null)
    });
  }

  const items = recipe.items.map(spec => ({
    _id: spec._id,
    name: spec.name,
    type: "equipment",
    img: spec.img,
    system: {
      apex: null,
      baseItem: null,
      bulk: {value: 0},
      description: {value: spec.description},
      equipped: {carryType: "worn", handsHeld: 0, invested: null, inSlot: false},
      hp: {max: 0, value: 0},
      hardness: 0,
      level: {value: 0},
      material: {grade: null, type: null},
      price: {per: 1, sizeSensitive: false, value: {}},
      publication: {license: "ORC", remaster: true, title: "Остров Кракена"},
      quantity: 1,
      rules: [],
      size: "med",
      slug: null,
      traits: {otherTags: ["story"], rarity: "unique", value: []},
      usage: {value: "worn"}
    },
    effects: [],
    flags: {[recipe.moduleId]: {designId: spec.designId}},
    _stats: stats(null)
  }));

  function makeLevel(color) {
    return {
      _id: "defaultLevel0000", name: "Основной уровень",
      background: {color, src: null, tint: "#ffffff", alphaThreshold: 0.75},
      foreground: {src: null, tint: "#ffffff", alphaThreshold: 0.75},
      elevation: {top: 20, bottom: 0}, fog: {src: null},
      textures: {anchorX: 0.5, anchorY: 0.5, offsetX: 0, offsetY: 0, fit: "fill", scaleX: 1, scaleY: 1, rotation: 0},
      visibility: {levels: []}, sort: 0, flags: {}
    };
  }

  const scenes = recipe.scenes.map(spec => ({
    _id: spec._id, name: spec.name, active: false, navigation: false, navOrder: 0, navName: "", thumb: null,
    width: 2000, height: 1600, padding: 0.25, shiftX: 0, shiftY: 0, initial: {x: 1000, y: 800, scale: 0.5},
    initialLevel: "defaultLevel0000",
    grid: {type: 1, size: 100, style: "solidLines", thickness: 1, color: "#000000", alpha: 0.2, distance: 5, units: "ft"},
    tokenVision: true,
    fog: {mode: 1, colors: {explored: null, unexplored: null}},
    environment: {
      darknessLevel: 0, darknessLock: false,
      globalLight: {enabled: false, alpha: 0.5, bright: false, color: null, coloration: 1, luminosity: 0, saturation: 0, contrast: 0, shadows: 0, darkness: {min: 0, max: 1}},
      cycle: true,
      base: {hue: 0, intensity: 0, luminosity: 0, saturation: 0, shadows: 0},
      dark: {hue: 0.7138888889, intensity: 0, luminosity: -0.25, saturation: 0, shadows: 0}
    },
    transition: {type: null, duration: 1500, activeOnly: false},
    drawings: [], tokens: [], levels: [makeLevel(spec.color)], lights: [], notes: [], sounds: [], regions: [], tiles: [], walls: [],
    playlist: null, playlistSound: null, journal: null, journalEntryPage: null, weather: "", folder: null, sort: spec.sort,
    ownership: {default: 0},
    flags: {[recipe.moduleId]: {designId: spec.designId, schematic: true}, pf2e: {rulesBasedVision: null, hearingRange: null, environmentTypes: []}},
    _stats: stats(null)
  }));

  const journal = [{
    _id: recipe.journal._id,
    name: recipe.journal.name,
    pages: recipe.journal.pages.map((page, index) => ({
      _id: page._id, name: page.name, type: "text", category: null, sort: (index + 1) * 100000,
      system: {}, title: {show: true, level: 1}, image: {}, text: {content: page.content, format: 1},
      video: {controls: true, volume: 0.5}, src: null, ownership: {default: -1}, flags: {}, _stats: stats(null)
    })),
    categories: [], folder: null, sort: 100000, ownership: {default: 0},
    flags: {[recipe.moduleId]: {designId: recipe.journal.designId}}, _stats: stats(null)
  }];

  const tables = [{
    _id: recipe.table._id, name: recipe.table.name, img: "icons/svg/d20-grey.svg",
    description: "<p>Слухи, которые можно услышать в Апертурах. Ни один результат не заменяет обязательный fail-forward.</p>",
    results: recipe.table.results.map((name, index) => ({
      _id: `RumorResult${String(index + 1).padStart(5, "0")}`, type: "text", name, description: "", img: null,
      documentUuid: null, weight: 1, range: [index + 1, index + 1], drawn: false, flags: {}, _stats: stats(null)
    })),
    formula: "1d6", replacement: true, displayRoll: true, folder: null, sort: 100000,
    ownership: {default: 0}, flags: {[recipe.moduleId]: {designId: recipe.table.designId}}, _stats: stats(null)
  }];

  const adventures = [{
    _id: "AperturaStart001",
    name: "Остров Кракена — Апертура",
    img: `modules/${recipe.moduleId}/assets/apertura-quickstart.png`,
    caption: "<p>Соль на пороге</p>",
    description: "<p>Небольшое приключение для персонажей 1-го уровня в деревне Апертура: таверна, проклятый храм, причал и необязательный дом Хьюго.</p>",
    actors: clone(actors),
    combats: [],
    items: clone(items),
    journal: clone(journal),
    scenes: clone(scenes),
    tables: clone(tables),
    macros: [],
    cards: [],
    playlists: [],
    folders: [],
    folder: null,
    sort: 100000,
    flags: {[recipe.moduleId]: {designId: "adventure-apertura-quickstart"}},
    _stats: stats(null)
  }];

  const buildRoot = path.join(root, `.pack-build-${process.pid}`);
  fs.rmSync(buildRoot, {recursive: true, force: true});
  fs.mkdirSync(buildRoot, {recursive: true});

  async function writePack(name, collection, documents, embedded = {}) {
    const target = path.join(buildRoot, name);
    const db = new ClassicLevel(target, {keyEncoding: "utf8", valueEncoding: "json"});
    await db.open();
    const operations = [];
    for (const original of documents) {
      const document = clone(original);
      for (const [field, childCollection] of Object.entries(embedded)) {
        const children = document[field] ?? [];
        document[field] = children.map(child => child._id);
        for (const child of children) operations.push({type: "put", key: `!${collection}.${childCollection}!${document._id}.${child._id}`, value: child});
      }
      operations.push({type: "put", key: `!${collection}!${document._id}`, value: document});
    }
    await db.batch(operations);
    await db.close();
  }

  await writePack("act-one-actors", "actors", actors, {items: "items"});
  await writePack("act-one-items", "items", items);
  await writePack("act-one-journal", "journal", journal, {pages: "pages", categories: "categories"});
  await writePack("act-one-scenes", "scenes", scenes, {drawings: "drawings", tokens: "tokens", levels: "levels", lights: "lights", notes: "notes", sounds: "sounds", regions: "regions", tiles: "tiles", walls: "walls"});
  await writePack("act-one-rumors", "tables", tables, {results: "results"});
  await writePack("apertura-adventure", "adventures", adventures);

  const packsRoot = path.join(root, "packs");
  fs.mkdirSync(packsRoot, {recursive: true});
  for (const name of ["act-one-actors", "act-one-items", "act-one-journal", "act-one-scenes", "act-one-rumors", "apertura-adventure"]) {
    const target = path.join(packsRoot, name);
    fs.rmSync(target, {recursive: true, force: true});
    fs.renameSync(path.join(buildRoot, name), target);
  }
  fs.rmSync(buildRoot, {recursive: true, force: true});
  console.log(JSON.stringify({actors: actors.length, items: items.length, journal: journal.length, scenes: scenes.length, tables: tables.length, adventures: adventures.length}));
JAVASCRIPT

stdout, stderr, status = Open3.capture3(
  node,
  "--input-type=module",
  "-e",
  script,
  ROOT.to_s,
  RECIPE.to_s,
  pf2e_data.to_s,
  classic_level.to_s,
  pf2e_source.to_s
)

warn stderr unless stderr.empty?
abort "Сборка паков завершилась с ошибкой" unless status.success?
puts "ПАКИ АПЕРТУРЫ СОБРАНЫ: #{stdout.strip}"
