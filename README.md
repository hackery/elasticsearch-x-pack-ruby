# Elasticsearch::XPack

A Ruby integration for the [X-Pack extensions](https://www.elastic.co/v5)
for Elasticsearch.


## Installation

Install the package from [Rubygems](https://rubygems.org):

    gem install elasticsearch-xpack --pre

To use an unreleased version, either add it to your `Gemfile` for [Bundler](http://gembundler.com):

    gem 'elasticsearch-xpack', git: 'git://github.com/elastic/elasticsearch-xpack-ruby.git'

or install it from a source code checkout:

    git clone https://github.com/elasticsearch/elasticsearch-xpack-ruby.git
    bundle install
    rake install

## Usage

If you use the official [Ruby client for Elasticsearch](https://github.com/elastic/elasticsearch-ruby),
require the library in your code, and all the methods will be automatically available in the `xpack` namespace:

```ruby
require 'elasticsearch'
require 'elasticsearch/xpack'

client = Elasticsearch::Client.new url: 'http://elastic:changeme@localhost:9200'

client.xpack.info
# => {"build"=> ..., "features"=> ...}
```

The integration is designed as a standalone `Elasticsearch::XPack::API` module, so it's easy
to mix it into a different client, and the methods will be available in the top namespace.

For documentation, look into the RDoc annotations in the source files, which contain links to the
official [X-Pack for the Elastic Stack](https://www.elastic.co/guide/en/x-pack/current/index.html) documentation.

For examples, look into the [`examples`](examples) folder in this repository.

## License

This software is licensed under the Apache 2 license, quoted below.

    Copyright (c) 2016 Elasticsearch <http://www.elasticsearch.org>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
