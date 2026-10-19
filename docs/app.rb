PICKER_INDICATOR_WIDTH = 24

class App
  def initialize
    @window = JS.global
    @document = JS.document
    @query = @window[:URLSearchParams].new(@window[:location][:search])
    @table_only = @query.get('tableonly') == 'true'
    @config_cache = {}
    @available_versions = []
    @rendering = false
    @render_requested = false
  end

  def el(id)
    @document.getElementById(id)
  end

  def create_element(type, attrs = {}, text = nil)
    e = @document.createElement(type)
    attrs.each { |k, v| e.setAttribute(k, v) }
    e[:textContent] = text unless text.nil?
    e
  end

  # JS::Object#fetch awaits each request in turn, so call the JS function directly to run requests in parallel.
  def request(path)
    [path, @window[:fetch].call(path)]
  end

  def parse_json(request)
    path, promise = request
    res = promise.await
    raise "#{path}: #{res[:status]}" unless res[:ok]

    JSON.parse(res.text.await)
  end

  def load_configs(ids)
    missing = ids.uniq.reject { |id| @config_cache.key?(id) }
    requests = missing.map { |id| request("json/#{id}/config.json") }
    missing.each_with_index { |id, i| @config_cache[id] = parse_json(requests[i]) }
    ids.map { |id| @config_cache[id] }
  end

  def available_ids
    @available_versions.map { |v| v['id'] }
  end

  def compare_versions(a, b)
    pa, pb = [a, b].map { |id| id.split('-')[1].split('.').map(&:to_i) }
    len = [pa.size, pb.size].max
    (pa + [0] * (len - pa.size)) <=> (pb + [0] * (len - pb.size))
  end

  def latest_version(ids)
    ids.sort { |a, b| compare_versions(a, b) }.last
  end

  def resolve_version(input)
    ids = available_ids
    ids.include?(input) ? input : latest_version(ids.select { |id| id.start_with?("#{input}.") })
  end

  def default_versions
    products = available_ids.map { |id| id.split('-')[0] }.uniq
    products.map { |product| latest_version(available_ids.select { |id| id.start_with?("#{product}-") }) }
  end

  def version_inputs
    @document.getElementsByName('version').to_a
  end

  # An exception escaping a listener kills its consumer task in PicoRuby.wasm 4.0.5, so every listener rescues.
  def listen(target, type, sync: false, &handler)
    target.addEventListener(type, sync: sync) do |event|
      handler.call(event)
    rescue => e
      @window[:console].error(e.message)
    end
  end

  def add_input(value = '')
    input = create_element('input', { 'name' => 'version', 'type' => 'search', 'list' => 'version_list' })
    input[:value] = value
    listen(input, 'change') { redisplay }
    listen(input, 'input') { redisplay if available_ids.include?(input[:value]) }
    # Browsers filter datalist options by the current value, so clear it while the list is opened from the indicator.
    listen(input, 'mousedown', sync: true) do |e|
      next if input[:value] == '' || e[:offsetX] < input[:clientWidth] - PICKER_INDICATOR_WIDTH

      input[:placeholder] = input[:value]
      input[:value] = ''
    end
    listen(input, 'blur', sync: true) do
      input[:value] = input[:placeholder] if input[:value] == '' && input[:placeholder] != ''
      input[:placeholder] = ''
    end
    el('versions').appendChild(input)
  end

  def apply_diff_only
    el('params')[:classList].toggle('only-diff', el('only_difference')[:checked])
  end

  def set_location
    q = @window[:URLSearchParams].new(@window[:location][:search])
    ['vers', 'diff', 'modules'].each { |key| q.delete(key) }
    vers = version_inputs.map { |input| input[:value] }.reject(&:empty?).join(',')
    q.set('vers', vers) unless vers.empty?
    q.set('diff', 'true') if el('only_difference')[:checked]
    q.set('modules', 'true') if el('include_modules')[:checked]
    search = q.toString.gsub('%2C', ',')
    @window[:history].replaceState(nil, '', search.empty? ? @window[:location][:pathname] : "?#{search}")
  end

  # Listeners run as concurrent tasks, so serialize renders and coalesce requests made while one is running.
  def redisplay
    @render_requested = true
    return if @rendering

    @rendering = true
    while @render_requested
      @render_requested = false
      begin
        render
      rescue => e
        @window.alert(e.message)
      end
    end
    @rendering = false
  end

  def render
    el('in-progress')[:style][:display] = 'block'
    ids = []
    inputs = version_inputs
    inputs.each_with_index do |input, i|
      value = input[:value] = input[:value].strip
      if value == ''
        input.remove if i < inputs.size - 1
        next
      end
      id = resolve_version(value)
      input[:classList].toggle('invalid-version', id.nil?)
      ids << id if id
    end
    add_input if version_inputs.last[:value] != ''
    set_location
    display_table(load_configs(ids))
  ensure
    el('in-progress')[:style][:display] = 'none'
  end

  def display_table(configs)
    include_modules = el('include_modules')[:checked]
    columns = configs.map do |config|
      { config: config, values: (include_modules && config['with_modules']) || config['base'] }
    end
    names = columns.map { |c| c[:values].keys }.flatten.uniq.sort

    table = create_element('table', { 'id' => 'param_table' })
    header = create_element('tr')
    header.appendChild(create_element('th', {}, 'Parameter'))
    columns.each do |column|
      config = column[:config]
      th = create_element('th', {}, "#{config['product']} #{config['version']}")
      th[:title] = config['modules'].map { |m| "#{m['name']} #{m['ver']}" }.join("\n") if include_modules && config['modules']
      header.appendChild(th)
    end
    table.appendChild(header)
    names.each { |name| table.appendChild(build_row(name, columns)) }
    el('params').replaceChildren(table)
  end

  def build_row(name, columns)
    values = columns.map { |c| c[:values][name] }
    tr = create_element('tr')
    tr[:className] = 'same-value' if values.uniq.size == 1
    tr.appendChild(build_name_cell(name, columns))

    prev_value = nil
    prev_words = nil
    values.each_with_index do |value, i|
      td = create_element('td', { 'class' => 'parameter-value' })
      words = nil
      if value.nil?
        td[:classList].add('unexist')
      else
        words = append_words(td, value)
        if i > 0 && prev_value != value
          td[:classList].add('difference')
          mark_word_diff(prev_words, words) if prev_words && whitespace?(prev_value + value)
        end
      end
      tr.appendChild(td)
      prev_value = value
      prev_words = words
    end
    tr
  end

  def build_name_cell(name, columns)
    td = create_element('td', { 'class' => 'parameter-name' })
    doc = columns.map { |c| c[:config]['docs'][name] }.compact.last
    if doc
      td.appendChild(create_element('a', { 'href' => doc, 'rel' => 'noreferrer noopener', 'target' => '_blank' }, name))
    else
      td[:textContent] = name
    end
    td
  end

  def whitespace?(s)
    s.match?(/\s/)
  end

  def split_pieces(value)
    pieces = []
    value.chars.each do |c|
      if pieces.empty? || whitespace?(pieces.last[0]) != whitespace?(c)
        pieces << c
      else
        pieces.last << c
      end
    end
    pieces
  end

  def append_words(td, value)
    words = []
    split_pieces(value).each do |piece|
      if whitespace?(piece[0])
        td.appendChild(@document.createTextNode(piece))
      else
        span = create_element('span', {}, piece)
        words << [piece, span]
        td.appendChild(span)
      end
    end
    words
  end

  def mark_word_diff(prev_words, words)
    a = prev_words.map(&:first)
    b = words.map(&:first)
    lcs = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
    (a.size - 1).downto(0) do |i|
      (b.size - 1).downto(0) do |j|
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : [lcs[i + 1][j], lcs[i][j + 1]].max
      end
    end
    i = 0
    j = 0
    while i < a.size && j < b.size
      if a[i] == b[j]
        i += 1
        j += 1
      elsif lcs[i + 1][j] >= lcs[i][j + 1]
        prev_words[i][1][:classList].add('del')
        i += 1
      else
        words[j][1][:classList].add('add')
        j += 1
      end
    end
    (i...a.size).each { |k| prev_words[k][1][:classList].add('del') }
    (j...b.size).each { |k| words[k][1][:classList].add('add') }
  end

  def start
    @available_versions = parse_json(request('json/versions.json'))
    unless @table_only
      el('header')[:hidden] = false
      el('footer')[:hidden] = false
    end

    datalist = create_element('datalist', { 'id' => 'version_list' })
    @available_versions.each do |v|
      datalist.appendChild(create_element('option', { 'value' => v['id'], 'label' => v['released_at'] }))
    end
    el('versions').appendChild(datalist)

    diff = el('only_difference')
    diff[:checked] = @query.get('diff') == 'true'
    listen(diff, 'change') do
      apply_diff_only
      set_location
    end

    modules = el('include_modules')
    modules[:checked] = @query.get('modules') == 'true'
    listen(modules, 'change') { redisplay }

    vers = @query.get('vers')&.split(',')&.map(&:strip)&.reject(&:empty?) || default_versions
    vers.each { |v| add_input(v) }
    add_input
    apply_diff_only
    redisplay
  rescue => e
    @window.alert(e.message)
  end
end

App.new.start
