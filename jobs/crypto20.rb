require 'rest-client'
require 'mongo'
require 'color'
require 'date'
require 'json'

current_value = 0
current_nav   = 0.to_f

# Database Variables
mongo_hostname = ENV['MONGO_HOSTNAME'] || '127.0.0.1'
mongo_port     = ENV['MONGO_PORT']     || '27017'
mongo_database = ENV['MONGO_DATABASE'] || 'main'
Mongo::Logger.logger.level = ::Logger::FATAL
@mongo = Mongo::Client.new([ "#{mongo_hostname}:#{mongo_port}" ], :database => mongo_database)

COLORS = {
  BTC:   "#F7931A",
  BCH:   "#F7931A",
  NEO:   "#4AB507",
  QTUM:  "#2895D8",
  EOS:   "#080809",
  HSR:   "#413176",
  OMG:   "#1536EC",
  ADA:   "#222222",
  ETH:   "#282828",
  LTC:   "#838383",
  XRP:   "#346AA9",
  XMR:   "#FF6600",
  DOGE:  "#BA9F33",
  MAID:  "#5492D6",
  STEEM: "#1A5099",
  XEM:   "#41bf76",
  DGD:   "#D8A24A",
  TIPS:  "#1b78bc",
  DASH:  "#1c75bc",
  LSK:   "#1A6896",
  BTS:   "#03A9E0",
  XLM:   "#03A9F9",
  PPC:   "#3FA30C",
  AMP:   "#048DD2",
  FCT:   "#2175BB",
  YBC:   "#D6C154",
  STRAT: "#2398dd",
  WAVES: "#24aad6",
  ICN:   "#4c6f8c",
  REP:   "#40a2cb",
  ZEC:   "#e5a93d",
  MIOTA: "#b9b9b9",
  ETC:   "#669073",
  NXT:   "#008FBB",
  SIA:   "#00CBA0",
  DAO:   "#FF3B3B",
  BTG:   "#F7931A",
}

def get_stat(stat)
  @mongo[:statistics].find({
    name: stat,
    }).first['value']
end

def holdings
  @mongo[:holdings].find
end

def historical_value(lim)
  @mongo[:historical_value].find.limit(lim).map do |entry|
    {
      time: entry['time'],
      value: entry['value'],
    }
  end
end

def get_holding(hldgs,name)
  hldgs[hldgs.index{|x|x['name'] == name}]
end

def calculate_percent_growth(history,coin)
  initial_value = get_holding(history.first['holdings'],coin)['value'].to_f
  final_value   = get_holding(history.last['holdings'],coin)['value'].to_f
  (final_value - initial_value) / initial_value
end

def calculate_value_growth(history,coin)
  initial_value = get_holding(history.first['holdings'],coin)['value']
  final_value   = get_holding(history.last['holdings'],coin)['value']
  final_value - initial_value
end

def values_to_graph(values,label_key,value_key)
  points = []
  labels = []
  x      = 1
  values.each do |value|
    points << {x: x, y: value[value_key]}
    labels << value[label_key]
    x += 1
  end
  { points: points, labels: labels }
end

SCHEDULER.every '3s' do
  # Get current value for graph
  current_value = get_stat('usd_value').to_f

  # Send an event to update the number but not the whole graph
  send_event('usd_value', value: current_value)

  # Calculate split
  split = []
  holdings.each do |asset|
    split << {
      value: asset['value'],
      color: COLORS[asset['name'].to_sym],
      label: asset['name']
    }
  end

  # Format the data correctly
  data = {
    datasets: [{
      data: split.map {|s| s[:value] },
      backgroundColor: split.map {|s| s[:color] },
    }],
    labels: split.map {|s| s[:label] },
  }
  send_event('split', data: data)

  # Calculate NAV
  current_nav = get_stat('nav_per_token').to_f

  percent     = ((current_nav - 1) / 1.00) * 100
  # If the percentage is negative, make it positive and set the arrow to down
  if percent < 0
    percent   = percent * -1.0
    direction = 'down'
  else
    direction = 'up'
  end
  send_event('nav', { current: current_nav.round(3), diff: percent.round(2), direction: direction })

  send_event('presale', current: get_stat('presale'))
  send_event('backers', current: get_stat('backers'))
end

# Populate Bubble chart
SCHEDULER.every "5s" do
  # Get the date that we want ot start from
  start_of_week = (Date.today - Date.today.wday) + 1

  # Get all of the holdings and convert taht to an array of hashes
  current_holdings = @mongo[:holdings].find.map { |h| h }

  # Create the query
  #
  # This is basically: "Give me all of the historical entries where the
  # distribution of coins is exactly as it is now"
  # This should give us all entries since trhe last rebalance regardless of when
  # that was
  this_week_query = []
  current_holdings.each do |holding|
    this_week_query << {
      'holdings' => {
        '$elemMatch' => {
          'name' => holding['name'],
          'amount' => holding['amount'],
        }
      }
    }
  end

  # Exacute the query to het historical holdings data
  this_week_history = @mongo[:historical_holdings].find({'$and' => this_week_query})

  # Map this to an array instead of an Enumerator
  this_week_history = this_week_history.map { |a| a }

  # Calculate how much each of these things have moved
  movements = []
  current_holdings.each do |holding|
    movements << {
      name: holding['name'],
      growth_percent: (calculate_percent_growth(this_week_history,holding['name'])*100).round(1),
      growth_value: calculate_value_growth(this_week_history,holding['name']),
      percent_of_fund: ((holding['value'].to_f / get_stat('usd_value').to_f) * 100.0).round(1)
    }
  end

  datasets = []
  movements.each do |movement|
    datasets << {
      label: movement[:name],
      backgroundColor: COLORS[movement[:name].to_sym],
      borderColor: Color::RGB.by_hex(COLORS[movement[:name].to_sym]).lighten_by(60).html,
      data: [{
        x: movement[:growth_percent],
        y: movement[:percent_of_fund],
        r: (movement[:growth_value] / 10000).abs,
      }],
      borderWidth: 2,
    }
  end

  send_event('contribution',{ datasets: datasets })
end


# I can't work out a nice way of providing the data to the clients initally when
# they load the dashobard. For now I'll just put a timer on and re-send the
# whole thing every two seconds. There must be a better way to do this
SCHEDULER.every "5s" do
  depth = 290
  data  = values_to_graph(historical_value(depth),:time,:value)
  send_event('usd_value', { points: data[:points], labels: data[:labels] })
end
#
# require 'pry'
# binding.pry
