require 'rubygems'
require 'bundler/setup'

Bundler.require(:default)

# ruby core requirements
require 'yaml'
require 'uri'
require 'json'

# used to symbolize the yaml config file
module HashExtensions
  def symbolize_keys
    inject({}) do |acc, (k,v)|
      key = String === k ? k.to_sym : k
    value = Hash === v ? v.symbolize_keys : v
    acc[key] = value
    acc
    end
  end
end
Hash.send(:include, HashExtensions)


#
# Config
#
configure do
  # configure by yaml file:
  yaml = YAML.load_file('config.yaml').symbolize_keys

  # apply environment specific options:
  yaml = yaml.merge yaml[settings.environment.to_sym]
  yaml.delete :production
  yaml.delete :development

  yaml.each_pair do |key, value|
    set(key, value)
  end

  enable :sessions
  enable :logging
  use Rack::Flash

  set :haml, {:format => :html5}

  set :sinatra_authentication_view_path, 'views/auth_'
  # NOTE: _must_ be disabled otherwise our custom error handler does not work correctly
  disable :show_exceptions
  disable :dump_errors
  disable :raise_errors 

  if settings.pagespeed
    use Rack::PageSpeed, :public => 'public' do
      store :disk => 'public'
      combine_javascripts
    end
  end
end


#
# Models
#
if settings.respond_to? 'datamapper_logger'
  puts "Setup DataMapper logging: #{settings.datamapper_logger}"
  DataMapper::Logger.new(STDOUT, settings.datamapper_logger)
end
if settings.database[:adapter] == 'mysql'
  Bundler.require(:mysql)
elsif settings.database[:adapter] == 'sqlite'
  Bundler.require(:sqlite)
end
DataMapper.setup(:default, settings.database)
 
 
class DmUser
  
  property :username, String

  def to_ary
    [self]
  end
end 
 
class Ballot
  include DataMapper::Resource
 
  property :id,           Serial
  property :created_at,   DateTime
 
  has n, :votes
   
  # voter
  belongs_to :dm_user, :required => false 
   
end
 
class Vote
  include DataMapper::Resource
 
  property :id,           Serial
  property :created_at,   DateTime
  property :value,				Integer 
  belongs_to :location
  belongs_to :ballot
end
 
class Location
  include DataMapper::Resource 
   
  property :id,           Serial
  property :title,        String
  property :name,         String
  property :description,	String
  property :category,			String
  property :url,          String
  property :enabled,			String 
  property :created_at,   DateTime
  property :updated_at, 	DateTime
end
 
class Option 
  include DataMapper::Resource 
   
  property :id,           Serial
  property :name,         String
  property :value,				Integer 
end


DataMapper.finalize
DataMapper.auto_upgrade!

#
# Helpers
#
helpers do

  include Rack::Utils
  alias_method :h, :escape_html

  def truncate(s, len=30)
    s[0...len] + (s.length > len ? '...' : '')
  end

  def partial(page, options={})
    unless @partials == false
      haml page, options.merge!(:layout => false)
    end
  end

  def sqlite_adapter?
    defined? DataMapper::Adapters::SqliteAdapter and
      repository(:default).adapter.class == DataMapper::Adapters::SqliteAdapter
  end

  def raw_sql(sql)
    repository(:default).adapter.select(sql)
  end

end


#
# Routes
# 

# index
get '/' do
  @title = "make your choice #{settings.pagetitle}"
  @locations = Location.all(:enabled => "on", :order => [:name.asc])
  
  @option1 = Option.first(:value => 2)
  @option2 = Option.first(:value => 1)
  @option3 = Option.first(:value => -1)
  @option4 = Option.first(:value => 0)

  if Ballot.count(:created_at.gte => Date.today, :dm_user_id => current_user.id) > 0
    flash[:notice] = "YOU have already voted, limit for today is reached!"
      redirect '/result'
  else
    haml :index
  end

end

# show all locations
get '/locations' do
  @title = "Locations at #{settings.pagetitle}"
  @locations = Location.all(:order => [:name.asc])

  haml :list_locations
end

# about page
get '/about' do
  @title = "About #{settings.pagetitle}"
  haml :about
end

# public stats and diagrams
get '/stats' do
  @title = "#{settings.pagetitle} in total numbers"

  # some stats in numbers
  # the rest is loaded from stats.json
  @stats = {
    :locations => Location.count,
    :users => DmUser.count,
    :ballots => Ballot.count
  }

  haml :stats
end

get '/stats.json' do
  logger.debug 'Generating stats json object'

  # location statistics
  user_stats = []
    Location.all(:enabled => 'on', :order => [:name]).each do | location |
    name = location.name
    count = raw_sql "SELECT SUM(value) AS sum FROM votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and l.id = #{location.id};"
    user_stats << [name, count[0].to_i] if count[0].to_i > 0
  end

  content_type :json
  {
    :user => user_stats
  }.to_json

end

#add new location
get '/new' do
  @title = "Submit a new location to #{settings.pagetitle}"
  haml :new_location
end

#submits new location
post '/new' do
  if logged_in?
    begin
      location = Location.new(:category => params['category'], 
                              :name => params['name'],
                              :url => params['url'],
                              :description => params['description'],
                              :enabled => params['enabled'])
      if location.save
      else
        raise 'Location create error: ' + item.errors.full_messages.join(', ')
      end

    rescue Exception => e
      logger.error "create error: #{e.class.to_s} #{e.to_s}"
      logger.error e.backtrace.join('\n')
      raise CreateItemError.new(e, location, tag_objects)
    end

    flash[:notice] = "Location ##{location.id} created."
      redirect '/locations'
  end
end


# view a location
get '/location/:name' do | name |
  @location = Location.first(:name => name)
  raise "location with id #{name} not found!" if not @location
  haml :view_location
end

# edit a location
get '/location/:id/edit' do |id|
  if logged_in?
    @location = Location.get(id)
  else
		raise 'WHAT Y DOING'
  end

  haml :edit_location 
end


# updates a location
post '/location/:id/edit' do
  # get the ocation to edit
  location = Location.get(params[:id])
  raise "location with id #{params[:id]} not found!" if not location

  if logged_in?
    location.update(:category => params[:category], :name => params[:name], :description => params[:description], :url => params[:url], :enabled => params[:enabled])
    flash[:notice] = "Location ##{params[:id]} updated."
      redirect '/locations' 
  else
    flash[:notice] = "Something went wron with location ##{params[:id]}."
      redirect '/locations'
  end
 
  @locations = Location.all(:order => [:name.asc]) 
  haml :list_locations
end


# deletes a location
post '/delete' do
  location = Location.get(params[:id])
  raise "location with id #{params[:id]} not found!" if not location

  if logged_in?
    location.destroy
    flash[:notice] = "Location ##{params[:id]} is gone now."
      redirect params['return_to']
  else    
    raise 'TEH HORSE IS WILD?'
  end 
end

# submits the vote
post '/vote' do
  if logged_in?
  
    #if sqlite_adapter?
    #    sql = 'SELECT * FROM ballots WHERE strftime("%d-%m-%Y", created_at) == strftime("%d-%m-%Y", "now") and dm_user_id == '
    #    sql << "#{current_user.db_instance.id};"
    #    res = raw_sql sql
    #    logger.debug('Custom SQL returned %d results.' % res.length)
    #end

    if Ballot.count(:created_at.gte => Date.today, :dm_user_id => current_user.id) > 0
    #if !res.empty?
      flash[:notice] = "YOU has already voted, limit for today is reached!"
      redirect '/result'
    end

    @locations = Location.all(:enabled => "on", :order => [:name.asc])
    ballot = Ballot.new(:dm_user => current_user.db_instance)  
    @locations.each do |location|
      #ballot = Ballot.new(:dm_user => current_user.db_instance)
      #option = Option.first(:value => params[:"#{location.id}"])
      ballot.votes << Vote.create(:location => location, :value => params[:"#{location.id}"])
      ballot.save
    end

    redirect '/result'
 
  else 
    flash[:notice] = "Please login to vote!"
      redirect '/login'
  end
end


# displays the vote results
get '/result' do
  if not logged_in?
    flash[:notice] = "Please vote first!"
        redirect '/'
  end

  if logged_in?
    if sqlite_adapter?
      sql = 'select v.value FROM dm_users as u, votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now")'
      sql = sql << " and u.id = b.dm_user_id and u.id = #{current_user.id} GROUP BY v.location_id order by l.name"
    end

    @voted = raw_sql sql
    logger.debug('Generate stats with custom SQL returned %d results.' % @voted.length)

    if @voted.length == 0
      flash[:notice] = "Please vote first!"
        redirect '/'
    end
  end

  #select sum pres and nogos for location
  if sqlite_adapter?
    sql = 'SELECT l.name, location_id, SUM(value) as sum, sum(case when value >= 2 then 1 else 0 end) as pros, sum(case when value = -1 then 1 else 0 end) as nogos FROM votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now") GROUP BY v.location_id ORDER BY l.name'
  end
  
  @today = Date.today
  @ballots = raw_sql sql
  logger.debug('Generate stats with custom SQL returned %d results.' % @ballots.length)

  #some bugs in aggregate  https://github.com/datamapper/dm-aggregates/issues/13
  #Vote.aggregate(:location_id, :value.sum, :unique => true, :fields => [:location_id, :Vote.locations.name], Vote.ballot.created_at.gte => Date.today-1, Vote.ballot.dm_user_id => 1)
  #@votes = Vote.aggregate(:location_id, :value.sum, :unique => true, :fields => [:location_id], Vote.ballot.created_at.gte => Date.today, Vote.ballot.dm_user_id => 1)

  #select userid for each user
  if sqlite_adapter?
    #sql = 'SELECT u.id, u.username FROM votes as v, dm_users as u , ballots as b where b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now") group by username ORDER BY username asc'
    sql = 'SELECT u.id, u.username FROM dm_users as u, votes as v, locations as l, ballots as b where  b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now") and u.id = b.dm_user_id GROUP BY u.id ORDER BY username asc'
  end

  @users = raw_sql sql
  logger.debug('Generate stats with custom SQL returned %d results.' % @users.length) 

  @results = Array.new
  @users.each do | user |
  
    #select voting values for each user and location
    if sqlite_adapter?
      sql = 'select v.value FROM dm_users as u, votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now")' 
      sql = sql << "and u.id = b.dm_user_id and u.id = #{user.id} GROUP BY v.location_id order by l.name"
    end

    @values = raw_sql sql
    @results.push(@values)

    logger.debug('Generate stats with custom SQL returned %d results.' % @values.length)
  end
  print @results
  haml :result
end

# displays the daily menu
get '/menu' do
  haml :menu
end


get '/favicon.ico' do
  redirect '/images/favicon.png'
end


def handle_error
  error = env['sinatra.error']
  code = (response.status == 200) ? 500 : response.status

  # Log exception that occured:
  logger.error "Error Handler: #{error.inspect}"
  logger.error "Backtrace: " + error.backtrace.join("\n")

  if not [Sinatra::NotFound, RuntimeError, StandardError].include? error.class
    error = RuntimeError.new 'unknown error occured'
  end

    flash[:error] = error.message
    redirect '/'

end

error 400..510 do # error RuntimeError do
  handle_error
end

error Exception do
  handle_error
end

# compile sass stylesheet
get '/stylesheet.css' do
  scss :stylesheet, :style => :compact
end




# create initial values
if Location.count(:name => 'Steindl') <= 0
  Location.create(:name => 'Steindl', :category => 'Restaurant', :url => 'http://www.restaurant-steindl.at/', :enabled => "on" )
  Location.create(:name => 'Mill', :category => 'Restaurant', :url => 'http://www.mill32.at/', :enabled => "on")
  Location.create(:name => 'Merkur', :category => 'Restaurant', :url => 'http://www.merkur.at', :enabled => "on")
  Location.create(:name => 'Vapiano', :category => 'Restaurant', :url => 'http://www.vapiano.at/', :enabled => "on")
  Location.create(:name => 'Yummy', :category => 'Chinese', :url => '', :enabled => "on") 
  Location.create(:name => 'Pizzeria', :category => 'Restaurant', :url => '', :enabled => "on")
  Location.create(:name => 'Mirchi', :category => 'Indian', :url => '', :enabled => "on") 
  Location.create(:name => 'Grieche', :category => 'Restaurant', :url => '', :enabled => "on")
  Location.create(:name => 'Cocos', :category => 'Chinese', :url => '', :enabled => "on")
  Location.create(:name => 'McDonalds', :category => 'Fast Food', :url => 'http://www.mcdonalds.at', :enabled => "on")
  Location.create(:name => 'Macas', :category => 'Fast Food', :url => '', :enabled => "on")
  Location.create(:name => 'LaDonnaInes', :category => 'Restaurant', :url => '', :enabled => "on")
  Location.create(:name => 'KFC', :category => 'Fast Food', :url => 'http://www.kfc.co.at/', :enabled => "")
  Location.create(:name => 'BurgerKing', :category => 'Fast Food', :url => 'http://www.burgerking.at', :enabled => "")
  Location.create(:name => 'Dots', :category => 'Restaurant', :url => '', :enabled => "")
  Location.create(:name => 'Monosushi', :category => 'Chinese', :url => '', :enabled => "")


  Option.create(:name => 'Want', :value => 2)
  Option.create(:name => 'OK', :value => 1)
  Option.create(:name => 'No Way', :value => -1)
  Option.create(:name => 'Maybe', :value => 0)
end
 

