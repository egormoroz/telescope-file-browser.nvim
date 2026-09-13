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
