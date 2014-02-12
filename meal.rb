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

  def get_special_values
    sql = 'SELECT l.name, location_id, l.url, SUM(value) as sum, sum(case when value >= 2 then 1 else 0 end) as pros, sum(case when value = -1 then 1 else 0 end) as nogos FROM votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now") GROUP BY v.location_id ORDER BY l.name'
  end
 
  def get_special_values_for_date(date)
     sql = "SELECT l.name, location_id, l.url, SUM(value) as sum, sum(case when value >= 2 then 1 else 0 end) as pros, sum(case when value = -1 then 1 else 0 end) as nogos FROM votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime('%Y-%m-%d', b.created_at) == '#{date}' GROUP BY v.location_id ORDER BY l.name"
  end

  def get_user_votes_by_location(user_id)
    sql = 'select v.value FROM dm_users as u, votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now")'
    sql = sql << "and u.id = b.dm_user_id and u.id = #{user_id} GROUP BY v.location_id order by l.name"
  end

end


#
# Routes
# 

# index
get '/' do
  @title = "make your choice #{settings.pagetitle}"
  @locations = Location.all(:enabled => "on", :order => [:category.asc])
  
  @option1 = Option.first(:value => settings.value_want)
  @option2 = Option.first(:value => settings.value_ok)
  @option3 = Option.first(:value => settings.value_noway)
  @option4 = Option.first(:value => settings.value_maybe)

  @startprevdate = Date.today - 1

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
  @locations = Location.all(:order => [:category.asc])

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
  @user = "#{current_user.username}"

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

  # global count function for location
  def count_by(id)
    counts = []
    if sqlite_adapter?
      sql = 'select l.name as name, sum(v.value) AS count from votes as v, ballots as b, dm_users as u, locations as l where v.ballot_id = b.id and u.id = b.dm_user_id and l.id = v.location_id and u.id = %s group by l.name' %id
    end
    res = raw_sql(sql)
    logger.debug('Generate stats with custom SQL returned %d results.' % res.length)
    res.each do |row|
      if row.count > 0
        counts << [row.name, row.count]
      end
    end
    return counts
  end

  if logged_in?
    user_single = count_by(current_user.id)
  end

  # for the piechart, user stats with all votepoints
  def user_sum
    sum = []
    if sqlite_adapter?
      sql = 'select u.username as username, sum(v.value) as sum from votes as v, ballots as b, dm_users as u where v.ballot_id = b.id and u.id = b.dm_user_id group by u.id order by u.username asc'
    end
    res = raw_sql(sql)
    logger.debug('Generate stats with custom SQL returned %d results.' % res.length)
    res.each do |row|
      if row.sum > 0
        sum << [row.username, row.sum]
      end
    end
    return sum
  end


  # location statistics for all locations
  user_stats = []
    Location.all(:enabled => 'on', :order => [:name]).each do | location |
    name = location.name
    count = raw_sql "SELECT SUM(value) AS sum FROM votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id and l.id = #{location.id};"
    logger.debug('Generate stats with custom SQL returned %d results.' % count.length)
    if count[0].to_i > 0
      user_stats << [name, count[0].to_i] if count[0].to_i > 0
    end
  end

  if logged_in?
    content_type :json
    {
      :user_sum => user_sum,
      :user => user_stats,
      :user_single => user_single
    }.to_json
  else
    content_type :json
    {
      :user_sum => user_sum,
      :user => user_stats
    }.to_json
  end
end

#add new location
get '/new' do
  if logged_in?
    @title = "Submit a new location to #{settings.pagetitle}"
    haml :new_location
  else
    flash[:notice] = "Login to add new location"
      redirect '/locations'
  end
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
    raise "location with id #{params[:id]} not found!" if not @location
  end

  haml :edit_location 
end


# updates a location
post '/location/:id/edit' do
  # get the ocation to edit
  location = Location.get(params[:id])
  raise "location with id #{params[:id]} not found!" if not location

  if logged_in?

    #get ballots for today    
    if sqlite_adapter?
      sql = 'select count(*) FROM ballots as b where strftime("%d-%m-%Y", b.created_at) == strftime("%d-%m-%Y", "now")'
    end
    @result = raw_sql sql
    logger.debug('Generate stats with custom SQL returned %d results.' % @result)

    #get actual enabled value, because a change in a running vote is not allowed
    if location.enabled != params[:enabled]
      if @result[0].to_i != 0
        flash[:error] = "Sorry voting for today is already in progress, do your updates tommorrow morning!"
          redirect '/locations'
      end     
    end

    location.update(:category => params[:category], :name => params[:name], :description => params[:description], :url => params[:url], :enabled => params[:enabled])
    flash[:notice] = "Location ##{params[:name]} updated."
      redirect '/locations' 
  else
    flash[:notice] = "Something went wrong with location ##{params[:name]}."
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
      flash[:notice] = "YOU have already voted, limit for today is reached!"
      redirect '/result'
    end

    #some checks for cheaters ;)
    params.values.each do |v|
      logger.info(v)
      if v.to_i > settings.value_want.to_i or v.to_i < settings.value_noway.to_i
        flash[:error] = "Uppps dont do this again!"
          redirect '/'
      end    
    end

    #check max nogos
    count = 0
    params.values.each do |v|
      if v.to_i == -1
        count=count+1
      end
    end
    
    if count > settings.max_nogos.to_i
      flash[:error] = "Only #{settings.max_nogos} nogos allowed!"
        redirect '/'
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

  #select sum, pros and nogos for location
  if sqlite_adapter?
    sql = get_special_values
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
      sql = get_user_votes_by_location(user.id)
    end

    @values = raw_sql sql
    @results.push(@values)

    logger.debug('Generate stats with custom SQL returned %d results.' % @values.length)
  end
  #print @results
  @startprevdate = Date.today-1
  @prevdate = Date.today-1
  @nextdate = Date.today+1
  haml :result
end

#displays the result of a given date
get '/result/:date/' do | date |
  if logged_in?
    if sqlite_adapter?
      sql = 'select v.value FROM dm_users as u, votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id'
      sql = sql << " and strftime('%Y-%m-%d', b.created_at) == '#{date}' and u.id = b.dm_user_id and u.id = #{current_user.id} GROUP BY v.location_id order by l.name"
    end

    @voted = raw_sql sql
    logger.debug('Generate stats with custom SQL returned %d results.' % @voted.length)

    begin
     Date.parse(params[:date])
    rescue ArgumentError
      # handle invalid date
      flash[:error] = "Wrong date DUDE!"
      redirect '/result'
    end

    #if today and not voted -> redirect
    @date = Date.parse params[:date]
    if Date.today == @date 
      if @voted.length == 0
        flash[:notice] = "Please vote first!"
        redirect '/'      
      end
    end
  else
    #if today and not logged in, prevent for spoilers
    @date = Date.parse params[:date]
    if Date.today == @date
      flash[:notice] = "Please vote first!"
      redirect '/'
    end
  end 

  #select sum, pros and nogos for location
  if sqlite_adapter?
    sql = get_special_values_for_date(date)
  end

  #calculate dates
  @date = Date.parse params[:date]
  @startprevdate = Date.today-1
  @prevdate = @date-1
  @nextdate = @date+1
  @ballots = raw_sql sql

  logger.debug('Generate stats with custom SQL returned %d results.' % @ballots.length)

  #select userid for each user that voted
  if sqlite_adapter?
    sql = 'SELECT u.id, u.username FROM dm_users as u, votes as v, locations as l, ballots as b where  b.id = v.ballot_id'
    sql = sql << " and strftime('%Y-%m-%d', b.created_at) == '#{date}' and u.id = b.dm_user_id GROUP BY u.id ORDER BY username asc"
  end

  @users = raw_sql sql
  logger.debug('Generate stats with custom SQL returned %d results.' % @users.length)

  @results = Array.new
  @users.each do | user |

    #select voting values for each user and location
    if sqlite_adapter?
      sql = 'select v.value FROM dm_users as u, votes as v, locations as l, ballots as b where l.id = v.location_id and b.id = v.ballot_id'
      sql = sql << " and strftime('%Y-%m-%d', b.created_at) == '#{date}' and u.id = b.dm_user_id and u.id = #{user.id} GROUP BY v.location_id order by l.name"
      #sql = get_user_votes_by_location(user.id)
    end

    @values = raw_sql sql
    @results.push(@values)

    logger.debug('Generate stats with custom SQL returned %d results.' % @values.length)
  end

  #if votes available or not
  if @users.length == 0
    haml :no_result
  else 
    haml :view_date_result
  end

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
#if Location.count(:name => 'Steindl') <= 0
#  Location.create(:name => 'Steindl', :category => 'Restaurant', :url => 'http://www.restaurant-steindl.at/', :enabled => "on" )
#  Location.create(:name => 'Mill', :category => 'Restaurant', :url => 'http://www.mill32.at/', :enabled => "on")
#  Location.create(:name => 'Merkur', :category => 'Restaurant', :url => 'http://www.merkur.at', :enabled => "on")
#  Location.create(:name => 'Vapiano', :category => 'Restaurant', :url => 'http://www.vapiano.at/', :enabled => "on")
#  Location.create(:name => 'Yummy', :category => 'Chinese', :url => '', :enabled => "on") 
#  Location.create(:name => 'Pizzeria', :category => 'Restaurant', :url => '', :enabled => "on")
#  Location.create(:name => 'Mirchi', :category => 'Indian', :url => '', :enabled => "on") 
#  Location.create(:name => 'Grieche', :category => 'Restaurant', :url => '', :enabled => "on")
#  Location.create(:name => 'Cocos', :category => 'Chinese', :url => '', :enabled => "on")
#  Location.create(:name => 'McDonalds', :category => 'Fast Food', :url => 'http://www.mcdonalds.at', :enabled => "on")
#  Location.create(:name => 'Macas', :category => 'Fast Food', :url => '', :enabled => "on")
#  Location.create(:name => 'LaDonnaInes', :category => 'Restaurant', :url => '', :enabled => "on")
#  Location.create(:name => 'KFC', :category => 'Fast Food', :url => 'http://www.kfc.co.at/', :enabled => "")
#  Location.create(:name => 'BurgerKing', :category => 'Fast Food', :url => 'http://www.burgerking.at', :enabled => "")
#  Location.create(:name => 'Dots', :category => 'Restaurant', :url => '', :enabled => "")
#  Location.create(:name => 'Monosushi', :category => 'Chinese', :url => '', :enabled => "")


#  Option.create(:name => 'Want', :value => settings.value_want)
#  Option.create(:name => 'OK', :value => settings.value_ok)
#  Option.create(:name => 'No Way', :value => settings.value_noway)
#  Option.create(:name => 'Maybe', :value => settings.value_maybe)
#end
 

