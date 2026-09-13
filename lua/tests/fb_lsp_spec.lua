if vim.fn.has "nvim-0.10" == 0 then
  return
end

local module_name = "telescope._extensions.file_browser.lsp"

describe("LSP file operations", function()
  local original_has, original_get_clients, original_module

  before_each(function()
    original_has = vim.fn.has
    original_get_clients = vim.lsp.get_clients
    original_module = package.loaded[module_name]
  end)

  after_each(function()
    vim.fn.has = original_has
    vim.lsp.get_clients = original_get_clients
    package.loaded[module_name] = original_module
  end)

  for _, modern in ipairs { false, true } do
    for _, operation in ipairs { "Create", "Rename", "Delete" } do
      for _, phase in ipairs { "will", "did" } do
        local capability = phase .. operation
        local method = "workspace/" .. capability .. "Files"
        local label = modern and "colon methods" or "Neovim 0.10 functions"
        it("filters " .. capability .. " independently for each client using " .. label, function()
          vim.fn.has = function(feature)
            if feature == "nvim-0.11" then
              return modern and 1 or 0
            end
            return original_has(feature)
          end
          package.loaded[module_name] = nil
          local lsp = require(module_name)
          local calls = {}
          local clients = {}

          for _, extension in ipairs { "lua", "zig" } do
            local client = {
              server_capabilities = {
                workspace = {
                  fileOperations = {
                    [capability] = { filters = { { pattern = { glob = "*." .. extension } } } },
                  },
                },
              },
            }
            local function check_call(...)
              local args = { ... }
              if modern then
                assert.are.equal(client, args[1])
                args = { select(2, ...) }
              end
              assert.are.equal(method, args[1])
              local expected
              if operation == "Rename" then
                expected = {
                  oldUri = vim.uri_from_fname("old." .. extension),
                  newUri = vim.uri_from_fname("new." .. extension),
                }
              else
                expected = { uri = vim.uri_from_fname("old." .. extension) }
              end
              assert.are.same({ files = { expected } }, args[2])
              calls[extension] = (calls[extension] or 0) + 1
              if phase == "will" then
                assert.is_nil(args[3])
                assert.are.equal(0, args[4])
                return {}
              end
              return true
            end
            client.request_sync = check_call
            client.notify = check_call
            table.insert(clients, client)
          end

          vim.lsp.get_clients = function(opts)
            assert.are.same({ method = method }, opts)
            return clients
          end
          local files = operation == "Rename" and { ["old.lua"] = "new.lua", ["old.zig"] = "new.zig" }
            or { "old.lua", "old.zig" }
          lsp[phase .. "_" .. operation:lower() .. "_files"](files)
          assert.are.same({ lua = 1, zig = 1 }, calls)
        end)
      end
    end
  end
end)

describe("LSP folder notifications after filesystem changes", function()
  local original_get_clients, root

  before_each(function()
    original_get_clients = vim.lsp.get_clients
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.lsp.get_clients = original_get_clients
    vim.fn.delete(root, "rf")
  end)

  for _, operation in ipairs { "rename", "delete" } do
    for _, subscribe_will in ipairs { false, true } do
      local label = subscribe_will and "will and did subscribers" or "did-only subscribers"
      it("preserves file and folder filters for " .. operation .. " with " .. label, function()
        local lsp = require(module_name)
        local folder, file = root .. "/folder", root .. "/file"
        vim.fn.mkdir(folder)
        vim.fn.writefile({ "contents" }, file)
        local files = operation == "rename" and { [folder] = folder .. "-new", [file] = file .. "-new" }
          or { folder, file }
        local suffix = operation == "rename" and "Rename" or "Delete"
        local calls = {}
        local clients = {}
        for _, kind in ipairs { "folder", "file" } do
          local filters = { { pattern = { glob = "**", matches = kind } } }
          local client = {
            server_capabilities = {
              workspace = {
                fileOperations = {
                  ["will" .. suffix] = { filters = filters },
                  ["did" .. suffix] = { filters = filters },
                },
              },
            },
          }
          local function capture(...)
            local method, params
            if vim.fn.has "nvim-0.11" == 1 then
              local self
              self, method, params = ...
              assert.are.equal(client, self)
            else
              method, params = ...
            end
            local path = kind == "folder" and folder or file
            local expected = operation == "rename"
                and { oldUri = vim.uri_from_fname(path), newUri = vim.uri_from_fname(files[path]) }
              or { uri = vim.uri_from_fname(path) }
            assert.are.same({ files = { expected } }, params)
            calls[method .. kind] = (calls[method .. kind] or 0) + 1
            return method:find("/will", 1, true) and {} or true
          end
          client.request_sync = capture
          client.notify = capture
          table.insert(clients, client)
        end
        vim.lsp.get_clients = function(opts)
          if not subscribe_will and opts.method:find("/will", 1, true) then
            return {}
          end
          return clients
        end

        local directories = lsp["will_" .. operation .. "_files"](files)
        if operation == "rename" then
          assert(vim.uv.fs_rename(folder, files[folder]))
          assert(vim.uv.fs_rename(file, files[file]))
        else
          assert.are.equal(0, vim.fn.delete(folder, "d"))
          assert.are.equal(0, vim.fn.delete(file))
        end
        assert.are.equal(0, vim.fn.isdirectory(folder))
        -- Even a replacement directory at the old file path must not change its kind.
        vim.fn.mkdir(file)
        lsp["did_" .. operation .. "_files"](files, directories)
        for _, kind in ipairs { "folder", "file" } do
          assert.are.equal(1, calls["workspace/did" .. suffix .. "Files" .. kind])
          assert.are.equal(subscribe_will and 1 or nil, calls["workspace/will" .. suffix .. "Files" .. kind])
        end
      end)
    end
  end
end)
