local local_vimrc = vim.fn.getcwd()..'/nvim_local.lua'
package.path = package.path .. ';' .. vim.fn.getcwd()
if vim.loop.fs_stat(local_vimrc) then
  cfg = require('nvim_local')
  return cfg.clangd or {}
end

return {}

