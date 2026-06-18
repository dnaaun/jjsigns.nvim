local _MODREV, _SPECREV = 'scm', '-2'

rockspec_format = "3.0"
package = 'jjsigns.nvim'
version = _MODREV .. _SPECREV

description = {
  summary = 'Git signs written in pure lua',
  detailed = [[
    Super fast git decorations implemented purely in Lua.
  ]],
  homepage = 'http://github.com/dnaaun/jjsigns.nvim',
  license = 'MIT/X11',
  labels = { 'neovim' }
}

dependencies = {
  'lua == 5.1',
}

source = {
  url = 'http://github.com/dnaaun/jjsigns.nvim/archive/v' .. _MODREV .. '.zip',
  dir = 'jjsigns.nvim-' .. _MODREV,
}

if _MODREV == 'scm' then
  source = {
    url = 'git://github.com/dnaaun/jjsigns.nvim',
  }
end

build = {
  type = 'builtin',
  copy_directories = {
    'doc',
    'plugin',
  },
}
