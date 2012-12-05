require 'rubygems'
require 'bundler'
require 'sinatra'

Bundler.require

set :env,  :production
disable :run

require "./server"

run Sinatra::Application
