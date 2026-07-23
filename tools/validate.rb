#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

ROOT = Pathname.new(__dir__).join("..").expand_path
MANIFEST_PATH = ROOT.join("module.json")
REGISTRY_PATH = ROOT.join("data", "document-registry.json")
EXPECTED_MODULE_ID = "kraken-island-pf2e-ru"
EXPECTED_DOCUMENT_COUNT = 18
EXPECTED_IMPLEMENTED_COUNT = 18
EXPECTED_PACKS = {
  "act-one-actors" => "Actor",
  "act-one-items" => "Item",
  "act-one-journal" => "JournalEntry",
  "act-one-scenes" => "Scene",
  "act-one-rumors" => "RollTable"
}.freeze

errors = []
source_specs_verified = false

def load_json(path, errors)
  JSON.parse(path.read)
rescue Errno::ENOENT
  errors << "нет файла #{path}"
  nil
rescue JSON::ParserError => e
  errors << "ошибка JSON в #{path}: #{e.message}"
  nil
end

def each_value(value, path = [], &block)
  case value
  when Hash
    value.each { |key, nested| each_value(nested, path + [key], &block) }
  when Array
    value.each_with_index { |nested, index| each_value(nested, path + [index], &block) }
  else
    yield(value, path)
  end
end

def collect_keys(value, key, path = [], found = [])
  case value
  when Hash
    value.each do |nested_key, nested|
      found << (path + [nested_key]).join(".") if nested_key == key
      collect_keys(nested, key, path + [nested_key], found)
    end
  when Array
    value.each_with_index { |nested, index| collect_keys(nested, key, path + [index], found) }
  end
  found
end

def duplicates(values)
  values.group_by { |value| value }.select { |_value, entries| entries.length > 1 }.keys
end

manifest = load_json(MANIFEST_PATH, errors)
registry = load_json(REGISTRY_PATH, errors)

if manifest
  required = %w[id type title description version compatibility relationships]
  missing = required.reject { |key| manifest.key?(key) }
  errors << "module.json: отсутствуют поля #{missing.join(', ')}" unless missing.empty?
  errors << "module.json: неверный id" unless manifest["id"] == EXPECTED_MODULE_ID
  errors << "module.json: type должен быть module" unless manifest["type"] == "module"
  errors << "module.json: minimum должен быть 14.365" unless manifest.dig("compatibility", "minimum") == "14.365"
  errors << "module.json: maximum должен ограничивать поколение 14" unless manifest.dig("compatibility", "maximum") == "14"

  %w[verified scripts esmodules].each do |forbidden_key|
    paths = collect_keys(manifest, forbidden_key)
    errors << "module.json: запрещено поле #{forbidden_key} (#{paths.join(', ')})" unless paths.empty?
  end

  packs = manifest["packs"]
  unless packs.is_a?(Array) && packs.length == EXPECTED_PACKS.length
    errors << "module.json: нужны пять паков вертикального среза"
  else
    actual_packs = packs.to_h { |pack| [pack["name"], pack["type"]] }
    errors << "module.json: состав паков не совпадает" unless actual_packs == EXPECTED_PACKS
    packs.each do |pack|
      errors << "module.json: Adventure pack запрещён на этом этапе" if pack["type"] == "Adventure"
      errors << "module.json: неверный путь pack #{pack['name']}" unless pack["path"] == "packs/#{pack['name']}"
      errors << "module.json: pack #{pack['name']} должен зависеть от pf2e" unless pack["system"] == "pf2e"
    end
  end

  systems = manifest.dig("relationships", "systems")
  unless systems.is_a?(Array) && systems.length == 1
    errors << "module.json: нужна ровно одна системная зависимость"
  else
    pf2e = systems.first
    errors << "module.json: системная зависимость должна быть pf2e" unless pf2e["id"] == "pf2e" && pf2e["type"] == "system"
    errors << "module.json: minimum PF2e должен быть 8.3.0" unless pf2e.dig("compatibility", "minimum") == "8.3.0"
  end

  each_value(manifest) do |value, path|
    next unless value.is_a?(String)
    if value.match?(%r{(?:file://|/Users/|iCloud~|^[A-Za-z]:\\)})
      errors << "module.json: внешний локальный путь в #{path.join('.')}"
    end
  end
end

if registry
  documents = registry["documents"]
  source_specs = registry.fetch("sourceSpecs", [])
  errors << "реестр: moduleId не совпадает" unless registry["moduleId"] == EXPECTED_MODULE_ID
  errors << "реестр: documentCount должен быть #{EXPECTED_DOCUMENT_COUNT}" unless registry["documentCount"] == EXPECTED_DOCUMENT_COUNT
  errors << "реестр: sourceSpecs должен быть непустым массивом" unless source_specs.is_a?(Array) && !source_specs.empty?

  unless documents.is_a?(Array)
    errors << "реестр: documents должен быть массивом"
    documents = []
  end
  errors << "реестр: фактически #{documents.length} записей вместо #{EXPECTED_DOCUMENT_COUNT}" unless documents.length == EXPECTED_DOCUMENT_COUNT

  ids = documents.map { |document| document["_id"] }
  design_ids = documents.map { |document| document["designId"] }
  namespaced = documents.map { |document| [document["documentType"], document["designId"]] }

  documents.each_with_index do |document, index|
    label = "реестр[#{index}]"
    errors << "#{label}: неверный _id #{document['_id'].inspect}" unless document["_id"].is_a?(String) && document["_id"].match?(/\A[A-Za-z0-9]{16}\z/)
    errors << "#{label}: неверный designId #{document['designId'].inspect}" unless document["designId"].is_a?(String) && document["designId"].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    errors << "#{label}: статус должен быть reserved или implemented" unless %w[reserved implemented].include?(document["status"])

    allowed_types = %w[Actor Item JournalEntry Scene RollTable]
    errors << "#{label}: неподдерживаемый documentType" unless allowed_types.include?(document["documentType"])
    if document["sourceType"] == "Hazard"
      errors << "#{label}: Hazard должен быть Actor/hazard" unless document["documentType"] == "Actor" && document["documentSubtype"] == "hazard"
    elsif document["sourceType"] == "Actor"
      errors << "#{label}: Actor должен быть Actor/npc" unless document["documentType"] == "Actor" && document["documentSubtype"] == "npc"
    end

    source_spec = document["sourceSpec"]
    errors << "#{label}: sourceSpec не входит в реестр внешних спецификаций" unless source_specs.include?(source_spec)
    errors << "#{label}: sourceSpec должен быть относительной ссылкой" unless source_spec.is_a?(String) && !Pathname.new(source_spec).absolute?
    if document["status"] == "implemented"
      errors << "#{label}: implemented-документ не связан с pack" unless EXPECTED_PACKS.key?(document["pack"])
      errors << "#{label}: pack не соответствует типу документа" unless EXPECTED_PACKS[document["pack"]] == document["documentType"]
    end
  end

  implemented = documents.count { |document| document["status"] == "implemented" }
  errors << "реестр: implemented должно быть #{EXPECTED_IMPLEMENTED_COUNT}, получено #{implemented}" unless implemented == EXPECTED_IMPLEMENTED_COUNT
  errors << "реестр: knownOmissions должен быть пуст в прототипе Апертуры" unless registry["knownOmissions"] == []

  duplicate_ids = duplicates(ids)
  duplicate_design_ids = duplicates(design_ids)
  duplicate_namespaced = duplicates(namespaced)
  errors << "реестр: дубликаты _id #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
  errors << "реестр: дубликаты designId #{duplicate_design_ids.join(', ')}" unless duplicate_design_ids.empty?
  errors << "реестр: дубликаты type/designId #{duplicate_namespaced.join(', ')}" unless duplicate_namespaced.empty?

  source_paths = source_specs.map { |relative_path| ROOT.join(relative_path).cleanpath }
  available_source_paths = source_paths.select(&:file?)
  if available_source_paths.any? && available_source_paths.length != source_paths.length
    missing_source_specs = source_specs.zip(source_paths).reject { |_relative_path, path| path.file? }.map(&:first)
    errors << "реестр: доступна только часть внешних спецификаций; отсутствуют #{missing_source_specs.join(', ')}"
  elsif available_source_paths.length == source_paths.length
    source_specs_verified = true
    source_rows = []
    source_specs.zip(source_paths).each do |relative_path, source_path|
      source_path.each_line do |line|
        match = line.match(/^\| ([^|]+?) \| ([^|]+?) \| `([^`]+)` \| `([A-Za-z0-9]+)` \|$/)
        next unless match

        source_rows << [relative_path, match[1].strip, match[2].strip, match[3], match[4]]
      end
    end

    registry_rows = documents.map do |document|
      [document["sourceSpec"], document["sourceType"], document["name"], document["designId"], document["_id"]]
    end
    missing_rows = registry_rows - source_rows
    extra_rows = source_rows - registry_rows
    errors << "реестр: #{missing_rows.length} записей не подтверждены спецификациями" unless missing_rows.empty?
    errors << "реестр: #{extra_rows.length} строк спецификаций не попали в реестр" unless extra_rows.empty?
  end
end

forbidden_code = Dir.glob(ROOT.join("**", "*").to_s).select do |path|
  File.file?(path) && %w[.js .mjs .cjs].include?(File.extname(path))
end
errors << "найден исполняемый JavaScript: #{forbidden_code.join(', ')}" unless forbidden_code.empty?
EXPECTED_PACKS.each_key do |pack_name|
  pack_path = ROOT.join("packs", pack_name)
  errors << "нет собранного pack #{pack_name}" unless pack_path.directory? && pack_path.join("CURRENT").file?
end

if errors.empty?
  puts "ПРОВЕРКА 1 — MANIFEST: ПРОЙДЕНА"
  puts "ПРОВЕРКА 2 — РЕЕСТР #{EXPECTED_DOCUMENT_COUNT} ДОКУМЕНТОВ АПЕРТУРЫ: ПРОЙДЕНА"
  puts(source_specs_verified ? "ПРОВЕРКА 2A — ВНЕШНИЕ СПЕЦИФИКАЦИИ: СВЕРЕНЫ" : "ПРОВЕРКА 2A — ВНЕШНИЕ СПЕЦИФИКАЦИИ: НЕ ВКЛЮЧЕНЫ В АВТОНОМНЫЙ МОДУЛЬ")
  puts "ПРОВЕРКА 3 — ПЯТЬ CONTENT-ONLY PACK БЕЗ ADVENTURE И JAVASCRIPT: ПРОЙДЕНА"
  exit 0
end

warn "ПРОВЕРКА НЕ ПРОЙДЕНА:"
errors.each { |error| warn "- #{error}" }
exit 1
