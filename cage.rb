require 'open-uri'
require 'nokogiri'
require 'opencv'
require 'RMagick'
require 'sidekiq'
require 'sinatra'
require 'sinatra/reloader'
require 'json'
require 'pusher'

Pusher.app_id = ENV['PUSHER_APP_ID']
Pusher.key    = ENV['PUSHER_KEY']
Pusher.secret = ENV['PUSHER_SECRET']

class ConversionWorker
  include Sidekiq::Worker

  sidekiq_options :retry => false, :backtrace => true

  def perform(vine_id)
    vine = Nokogiri::HTML(open("https://vine.co/v/#{vine_id}"))

    vine = vine.xpath('//meta[@property="twitter:player:stream"]').first.attributes['content']

    filename = Digest::SHA1.hexdigest(vine_id)

    Pusher.trigger(filename, 'update_status', 'Downloading video from Vine...')

    `wget -O tmp/video/#{filename}.mp4 #{vine}`

    FileUtils.mkdir("tmp/stills/#{filename}") unless File.exists?("tmp/stills/#{filename}")

    Pusher.trigger(filename, 'update_status', 'Splitting up video into individual frames...')

    `ffmpeg -y -r 20 -vcodec libx264 -i tmp/video/#{filename}.mp4 -r 20 -f image2 tmp/stills/#{filename}/frame%07d.png`

    Pusher.trigger(filename, 'update_status', 'Adding Sir Nicolas Cage...')

    detector = OpenCV::CvHaarClassifierCascade::load('haarcascades/haarcascade_frontalface_alt.xml')

    cage = Magick::Image.read('cage.png').first

    Dir.glob("tmp/stills/#{filename}/*.png") do |file|
      puts file
      cv_image = OpenCV::CvMat.load(file)
      im_image = Magick::Image.read(file).first

      detector.detect_objects(cv_image).each do |region|
        cage_to_composite = cage.resize_to_fit(region.width, im_image.rows)

        offset = cage_to_composite.rows / 8

        im_image.composite!(cage_to_composite, region.top_left.x, region.top_left.y - offset, Magick::OverCompositeOp)  
      end

      im_image.write(file)
    end

    Pusher.trigger(filename, 'update_status', 'Stealing the declaration of independence...')

    `ffmpeg -y -r 20 -i tmp/stills/#{filename}/frame%07d.png -vcodec libx264 -r 20 public/video/#{filename}.mp4`

    FileUtils.rm_rf("tmp/stills/#{filename}")
    FileUtils.rm_rf("tmp/video/#{filename}.mp4")

    Pusher.trigger(filename, 'done', filename)
  end
end

set :server, :puma

get '/' do
  erb :index
end

post '/cageify' do
  content_type :json

  url = params[:url]

  halt 400 unless url and match = url.match(/\Ahttp(s)?:\/\/vine.co\/v\/([A-Za-z0-9]+)(\/.+)?\z/)

  id        = match[2].to_s
  hashed_id = Digest::SHA1.hexdigest(id)

  return {:status => 'done', :id => hashed_id}.to_json if File.exists?("public/video/#{hashed_id}.mp4")

  ConversionWorker.perform_async(id)

  {:status => 'queued', :id => hashed_id}.to_json
end

get '/v/:id' do
  id = params[:id]

  raise Sinatra::NotFound unless File.exists?("public/video/#{id}.mp4")

  erb :video, :locals => {:id => id}
end