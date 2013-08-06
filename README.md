Mealtime
--------

Mealtime is a free software media gallery built with Sinatra.

based on the amazing zeitgeist.li.

This is work in progress, come and join the fun!

Current Features
----------------

* Vote for the daily lunch
* Add Locations
* Sign up to vote
* Statistics

Development
-----------

* fork (on github)
* (install [rvm](http://rvm.beginrescueend.com/) and use the 2.0.0 ruby)
* rvm use 2.0.0
* rvm gemset create meal
* git clone git@github.com:username/mealtime.git
* cd mealtime 
* gem install bundler && bundle install
* cp config.yaml.sample config.yaml
* shotgun -E development config.ru
