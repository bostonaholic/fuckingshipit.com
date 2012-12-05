$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__) + '/lib')).uniq!

require "sinatra"
require "haml"

require "config"
require "helpers"

get "/" do
  haml :welcome
end

not_found do
  redirect "/"
end
