local promise = require('promise')
local bufmanager = require('ufo.bufmanager')
local foldingrange = require('ufo.model.foldingrange')
local utils = require('ufo.utils')

local api = vim.api

---@class UfoTreesitterProvider
---@field hasProviders table<string, boolean>
local Treesitter = {
    hasProviders = {}
}

---@diagnostic disable: deprecated
---@return vim.treesitter.LanguageTree|nil parser for the buffer, or nil if parser is not available
local function getParser(bufnr, lang)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok then
        return nil
    end
    return parser
end
local get_query = assert(vim.treesitter.query.get or vim.treesitter.query.get_query)
local get_query_files = assert(vim.treesitter.query.get_files or vim.treesitter.query.get_query_files)
---@diagnostic enable: deprecated


-- Backward compatibility for the dummy directive (#make-range!),
-- which no longer exists in nvim-treesitter v1.0+
if not vim.tbl_contains(vim.treesitter.query.list_directives(), 'make-range!') then
    vim.treesitter.query.add_directive('make-range!', function() end, {})
end

local MetaNode = {}
MetaNode.__index = MetaNode

function MetaNode:new(range, type)
    local o = self == MetaNode and setmetatable({}, self) or self
    o._range = range
    o._type = type
    return o
end

function MetaNode:range()
    local range = self._range
    return range[1], range[2], range[3], range[4]
end

function MetaNode:type()
    return self._type
end

--- Return a meta node that represents a range between two nodes, i.e., (#make-range!),
--- that is similar to the legacy TSRange.from_node() from nvim-treesitter.
function MetaNode.from_nodes(startNode, endNode, nodeType)
    local start_pos = {startNode:start()}
    local end_pos = {endNode:end_()}
    return MetaNode:new({
        [1] = start_pos[1],
        [2] = start_pos[2],
        [3] = end_pos[1],
        [4] = end_pos[2],
    }, nodeType)
end

local makeRangePatternsCache = setmetatable({}, {__mode = 'k'})

local function getMakeRangePatterns(q)
    local res = makeRangePatternsCache[q]
    if res then
        return res
    end
    res = {}
    for pattern, preds in pairs(q.info.patterns) do
        for _, pred in pairs(preds) do
            if pred[1] == 'make-range!' and type(pred[2]) == 'string' and #pred == 4 then
                res[pattern] = res[pattern] or {}
                table.insert(res[pattern], pred)
            end
        end
    end
    makeRangePatternsCache[q] = res
    return res
end

local function addRange(ranges, startRow, endRow, endCol, typeNode)
    if endCol == 0 then
        endRow = endRow - 1
    end
    if endRow > startRow then
        local nType = typeNode and typeNode.type and typeNode:type() or nil
        table.insert(ranges, foldingrange.new(startRow, endRow, nil, nil, nType))
    end
end

local function collectFoldRanges(ranges, bufnr, root, lang)
    local q = get_query(lang, 'folds')
    if not q then
        return
    end
    local makeRangePatterns = getMakeRangePatterns(q)
    local startRow, _, endRow = root:range()
    -- The end row is exclusive so we need to add 1 to it.
    for pattern, match, metadata in q:iter_matches(root, bufnr, startRow, endRow + 1) do
        for id, nodes in pairs(match) do
            local first, last = nodes, nodes
            if type(nodes) == 'table' then
                first, last = nodes[1], nodes[#nodes]
            end
            local m = metadata[id]
            if m and m.range then
                addRange(ranges, m.range[1], m.range[3], m.range[4], first)
            elseif first == last then
                local sRow, _, eRow, eCol = first:range()
                addRange(ranges, sRow, eRow, eCol, first)
            else
                local sRow = first:start()
                local eRow, eCol = last:end_()
                addRange(ranges, sRow, eRow, eCol, first)
            end
        end
        local preds = makeRangePatterns[pattern]
        if preds then
            for _, pred in ipairs(preds) do
                local node = MetaNode.from_nodes(match[pred[3]], match[pred[4]])
                local sRow, _, eRow, eCol = node:range()
                addRange(ranges, sRow, eRow, eCol, node)
            end
        end
    end
end

local function getFoldRanges(bufnr, parser)
    local hasQuery = false
    local ranges = {}
    parser:for_each_tree(function(tree, langTree)
        local lang = langTree:lang()
        if #get_query_files(lang, 'folds', nil) > 0 then
            hasQuery = true
            collectFoldRanges(ranges, bufnr, tree:root(), lang)
        end
    end)
    return hasQuery, ranges
end

local function getFoldsFromParser(bufnr, parser, ft)
    local ok, ranges = getFoldRanges(bufnr, parser)
    if not ok then
        Treesitter.hasProviders[ft] = false
        error('UfoFallbackException')
    end
    foldingrange.sortRanges(ranges)
    return ranges
end

function Treesitter.getFolds(bufnr)
    local buf = bufmanager:get(bufnr)
    if not buf then
        return
    end
    local bt = buf:buftype()
    if bt ~= '' and bt ~= 'acwrite' then
        if bt == 'nofile' then
            error('UfoFallbackException')
        end
        return
    end
    local self = Treesitter
    local ft = buf:filetype()
    if self.hasProviders[ft] == false then
        error('UfoFallbackException')
    end
    local parser = getParser(bufnr)
    if not parser then
        self.hasProviders[ft] = false
        error('UfoFallbackException')
    end
    if not utils.has11() then
        return getFoldsFromParser(bufnr, parser, ft)
    end
    return promise(function(resolve, reject)
        parser:parse(nil, function(err)
            if err then
                reject('UfoFallbackException')
                return
            end
            if not api.nvim_buf_is_valid(bufnr) then
                resolve()
                return
            end
            local ok, res = pcall(getFoldsFromParser, bufnr, parser, ft)
            if ok then
                resolve(res)
            else
                reject(res)
            end
        end)
    end)
end

function Treesitter:dispose()
    self.hasProviders = {}
end

return Treesitter
