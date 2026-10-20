#!/usr/bin/env node
// Maintenance tool only; KOReader's runtime does not require Node.js.
// Derived data and test cases: GPL-3.0-or-later, Yomitan/Yomichan Authors.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import path from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';
import vm from 'node:vm';

const revision = '876253ca12e38aa6b0be3617e84827db5d9782b3';
const checkout = path.resolve(process.argv[2] || '');
assert.equal(execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(), revision,
    'Use the pinned Yomitan checkout (see plugins/yomitan.koplugin/README.md)');
execFileSync('git', ['-C', checkout, 'diff', '--exit-code', 'HEAD', '--', 'ext/js/language', 'test/language/japanese-transforms.test.js']);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const integrated = existsSync(path.join(root, 'plugins/yomitan.koplugin'));
const plugin = path.join(root, integrated ? 'plugins/yomitan.koplugin' : 'yomitan.koplugin');
const load = (file) => import(pathToFileURL(path.join(checkout, file)));
const {japaneseTransforms} = await load('ext/js/language/ja/japanese-transforms.js');
const {LanguageTransformer} = await load('ext/js/language/language-transformer.js');
const transformer = new LanguageTransformer();
transformer.addDescriptor(japaneseTransforms);
const source = `https://github.com/yomidevs/yomitan/tree/${revision}`;
const metadata = {
    revision, source, license: 'GPL-3.0-or-later',
    copyright: ['Copyright (C) 2024-2026 Yomitan Authors', 'Copyright (C) 2023-2026 Yomitan Authors',
        'Copyright (C) 2020-2022 Yomichan Authors', 'Copyright (C) 2016-2022 Yomichan Authors'],
};
const transforms = transformer._transforms.map(({id, rules}) => ({
    id,
    rules: rules.map((rule) => {
        assert(['suffix', 'wholeWord'].includes(rule.type));
        const pattern = rule.isInflected.source;
        assert(pattern.endsWith('$'));
        const input = pattern.slice(rule.type === 'wholeWord' ? 1 : 0, -1);
        assert(input.length > 0 && !/[.*+?^${}()|[\]\\]/u.test(input), 'New regex rule needs an explicit port');
        return {type: rule.type, input, output: rule.deinflect(input),
            conditionsIn: rule.conditionsIn, conditionsOut: rule.conditionsOut};
    }),
}));
const data = {...metadata, conditionTypes: Object.fromEntries(transformer._conditionTypeToConditionFlagsMap),
    dictionaryConditions: Object.fromEntries(transformer._partOfSpeechToConditionFlagsMap), transforms};
writeFileSync(path.join(plugin, 'yomitan/yomitan-transforms.json'), JSON.stringify(data, null, 2) + '\n');

const testSource = readFileSync(path.join(checkout, 'test/language/japanese-transforms.test.js'), 'utf8');
const start = testSource.indexOf('const tests = ');
const end = testSource.indexOf('const languageTransformer = ');
assert(start >= 0 && end > start);
const cases = vm.runInNewContext(testSource.slice(start, end) + '\ntests;');
const oracleSources = ['読んでいる', '走っていました', '食べられなかった', '申し込んだ', '取り戻せなかった',
    '来ませんでした', 'こられなかった', 'なさいます', 'おっしゃいます', '食べさせられる', '食べさされる',
    '食べちゃった', '行こっか', '読まへんかった', '買うた', '思ふ', '美しくありませんでした', 'まい', '図書館'];
const oracle = oracleSources.map((text) => ({text, results: transformer.transform(text).map(({text: term, conditions, trace}) => ({
    term, conditions, trace, reasons: trace.map((frame) => frame.transform),
}))}));
// Execute actual Translator candidate/matching/source-length methods. Only its
// unrelated UI-entry constructor and multilingual collaborators are substituted.
const translatorSource = readFileSync(path.join(checkout, 'ext/js/language/translator.js'), 'utf8')
    .replace(/^import .*;$/gm, '').replace('export class Translator', 'class Translator');
class JapaneseOnlyTransformer {
    transform(_language, text) { return transformer.transform(text); }
    getConditionFlagsFromPartsOfSpeech(_language, rules) { return transformer.getConditionFlagsFromPartsOfSpeech(rules); }
}
const Translator = vm.runInNewContext(translatorSource + '\nTranslator;', {
    LanguageTransformer, MultiLanguageTransformer: JapaneseOnlyTransformer, Intl,
    safePerformance: {mark() {}, measure() {}}, MAX_PROCESS_VARIANTS: 128,
});
const pipelineCases = [
    {text: '読んでいる猫', entries: [{term: '読む', rules: ['v5']}], filter: true},
    {text: '美しく', entries: [{term: '美しい', rules: ['adj-i']}], filter: true},
    {text: '美しく', entries: [{term: '美しい', rules: ['v1']}], filter: true},
    {text: '食べ', entries: [{term: '食べる', rules: ['v1']}], filter: true},
    {text: '食べ', entries: [{term: '食べる', rules: ['v5']}], filter: true},
    {text: 'できる', entries: [{term: 'する', rules: ['vs']}], filter: true},
    {text: 'できる', entries: [{term: 'する', rules: ['v5']}], filter: true},
    {text: '猫', entries: [{term: '猫', rules: []}], filter: true},
    {text: '読んでいる', entries: [{term: '読む', rules: []}], filter: false},
    {text: '読んでいる', entries: [{term: '読む', rules: []}], filter: true},
    {text: 'スマートフォン', entries: [{term: 'スマート', rules: []}, {term: 'スマートフォン', rules: []}], filter: false},
];
const pipeline = [];
for (const testCase of pipelineCases) {
    let requested;
    const database = {async findTermsBulk(words) {
        requested ??= words;
        return words.flatMap((word, index) => testCase.entries.flatMap((entry, id) => entry.term === word ?
            [{...entry, id, index, dictionary: 'fixture', definitions: ['fixture']}] : []));
    }};
    const translator = new Translator(database);
    translator._textProcessors.set('ja', {textPreprocessors: [], textPostprocessors: []});
    translator._createTermDictionaryEntryFromDatabaseEntry = (entry, _originalText, transformedText,
        _deinflectedText, textProcessorRuleChainCandidates, inflectionRuleChainCandidates) => ({
        definitions: [{id: entry.id}], headwords: [{sources: [{transformedText}]}],
        textProcessorRuleChainCandidates, inflectionRuleChainCandidates,
    });
    const enabledDictionaryMap = new Map([['fixture', {partsOfSpeechFilter: testCase.filter}]]);
    const options = {language: 'ja', deinflect: true, searchResolution: 'letter', matchType: 'exact',
        textReplacements: [null], enabledDictionaryMap};
    const states = await translator._getDeinflections(testCase.text, options);
    const {originalTextLength} = translator._getDictionaryEntries(states, enabledDictionaryMap, null, '');
    pipeline.push({...testCase, requested, originalTextLength});
}
// Keep fork-specific reference data in the parent repo, not the test submodule.
const fixtures = path.join(root, integrated ? 'spec/unit/fixtures/yomitan' : 'tools/generated-fixtures/yomitan');
mkdirSync(fixtures, {recursive: true});
writeFileSync(path.join(fixtures, 'yomitan-transforms.json'), JSON.stringify({...metadata, cases, oracle, pipeline}, null, 2) + '\n');
console.log(`${transforms.length} transforms, ${transforms.reduce((n, t) => n + t.rules.length, 0)} rules; ` +
    `${cases.reduce((n, c) => n + c.tests.length, 0)} upstream assertions, ${oracle.length} full-output oracles, ` +
    `${pipeline.length} Translator search oracles`);
