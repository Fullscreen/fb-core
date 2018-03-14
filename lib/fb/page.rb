module Fb
  # Provides methods to interact with Facebook pages through the Graph API.
  # @see https://developers.facebook.com/docs/graph-api/reference/page/
  class Page < Resource
    # @option [String] the page’s unique ID.
    attr_reader :id

    # @option [String] the page’s name.
    attr_reader :name

    # @option [String] the page’s category.
    attr_reader :category

    # @param [Hash] options to initialize a Page object.
    # @option [String] :id The page’s unique ID.
    # @option [String] :name The page’s name.
    # @option [String] :category The page’s category.
    # @option [String] :access_token an access token for the page.
    def initialize(options = {})
      @id = options[:id]
      @name = options[:name]
      @category = options[:category]
      @access_token = options[:access_token]
    end

    # @return [Hash<Date, Integer>]  a hash of Dates mapped to their values.
    # @param [String] :metric the metric to fetch.
    # @param [<String, Symbol>] :period the aggregate period (day, week, days_28).
    # @option [Date] :since only return dates ahead to this date (lower bound).
    # @option [Date] :until only return dates previous to this day (upper bound).
    def metric_insights(metric, period, options = {})
      insights = page_insights Array(metric), options.merge(period: period)
      values = insights.find{|data| data['name'] == metric}['values']
      values.map do |v|
        [Date.strptime(v['end_time'], '%Y-%m-%dT%H:%M:%S+0000'), v.fetch('value', 0)]
      end.to_h
    end

    # @return [Hash] a hash of metrics mapped to their values.
    # @param [Array<String, Symbol>] :metrics the metrics to fetch.
    # @option [Date] :until only sum seven days before this date.
    def weekly_insights(metrics, options = {})
      since_date = options.fetch :until, Date.today - 1
      params = {period: :week, since: since_date, until: since_date + 2}
      metrics = page_insights Array(metrics), params
      metrics.map {|m| [m['name'].to_sym, m['values'].last.fetch('value', 0)]}.to_h
    end

    # @return [Integer] the number of views of the page.
    # @param [Hash] options the options
    # @option [Date] :until only count the views until this day.
    def view_count(options = {})
      views = metric_insights 'page_views_total', 'day', since: '1652 days ago'
      views.select!{|date, _| date < options[:until]} if options[:until]
      views.values.sum
    end

    # @return [Integer] the number of likes of the page.
    # @param [Hash] options the options
    # @option [Date] :until only count the likes until this day.
    def like_count(options = {})
      since_date = options.fetch :until, Date.today - 1
      likes = metric_insights 'page_fans', 'lifetime', since: since_date, until: since_date + 2
      likes[since_date+1]
    end

    # @return [Array<Fb::Post>] the posts published on the page.
    # @option [Time] :since only return posts ahead of this time.
    # @option [Time] :until only return posts previous to this time.
    # @option [Boolean] :with_metrics whether to include insights for the posts.
    def posts(options = {})
      @posts ||= begin
        params = posts_params.merge options
        request = PaginatedRequest.new path: "/v2.9/#{@id}/posts", params: params
        data = request.run.body['data']
        options[:with_metrics] ? posts_with_metrics_from(data) : posts_from(data)
      end
    end

    # @return [Array<Fb::Video>] the uploaded videos for the page.
    def videos
      @videos ||= begin
        request = PaginatedRequest.new path: "/v2.9/#{@id}/videos", params: video_params
        data = request.run.body['data']
        videos_with_metrics_from(data)
      end
    end

    # @return [String] the representation of the page.
    def to_s
      %Q(#<#{self.class.name} #{@id} "#{@name}">)
    end

  private

    def page_insights(metrics, options = {})
      insights(metrics, options.merge(ids: id, access_token: page_access_token))[id]['data']
    end

    def page_access_token
      @page_access_token ||= begin
        params = {fields: 'access_token', access_token: @access_token}
        request = HTTPRequest.new path: "/v2.9/#{@id}", params: params
        request.run.body["access_token"]
      end
    end

    def posts_from(data)
      data.map do |post_data|
        Post.new symbolize_keys post_data
      end
    end

    def posts_with_metrics_from(data)
      data.each_slice(50).flat_map do |post_slice|
        post_ids = post_slice.map{|post| post['id']}.join ','
        metrics = insights post_metrics, ids: post_ids, period: :lifetime
        post_slice.map do |post_data|
          insights_data = metrics[post_data['id']]['data'].map do |metric|
            [metric['name'], metric['values'].last.fetch('value', 0)]
          end.to_h
          Post.new symbolize_keys post_data.merge(insights_data)
        end
      end
    end

    def insights(metrics, options = {})
      params = {metric: metrics.join(','), access_token: @access_token}.merge options
      request = HTTPRequest.new path: "/v2.9/insights", params: params
      request.run.body
    end

    def posts_params
      {}.tap do |params|
        params[:access_token] = @access_token
        params[:limit] = 100
        params[:fields]= ['id', 'message', 'permalink_url', 'created_time', 'type', 'properties', 'shares',
          'comments.limit(0).summary(true)', 'likes.limit(0).summary(true)', 'reactions.limit(0).summary(true)'].join(',')
      end
    end

    # https://developers.facebook.com/docs/graph-api/reference/v2.10/insights
    def post_metrics
      %i(post_engaged_users post_video_views_organic post_video_views_paid post_video_views post_video_view_time
      post_impressions post_video_avg_time_watched)
    end

    def videos_with_metrics_from(data)
      data.each_slice(25).flat_map do |video_slice|
        video_ids = video_slice.map {|video| video['id']}.join(',')
        metrics = video_insights(video_metrics, ids: video_ids)
        video_slice.map do |video_data|
          insights_data = metrics[video_data['id']]['data'].map do |metric|
            [metric['name'], metric['values'].last.fetch('value', 0)]
          end.to_h
          Video.new symbolize_keys video_data.merge(insights_data)
        end
      end
    end

    def video_insights(metrics, options = {})
      params = options.merge metric: metrics.join(','), access_token: @access_token
      request = HTTPRequest.new path: "/v2.9/video_insights", params: params
      request.run.body
    end

    def video_params
      {}.tap do |params|
        params[:access_token] = @access_token
        params[:limit] = 25
        params[:fields] = ['id', 'permalink_url', 'custom_labels', 'title',
          'length', 'content_tags', 'likes.limit(0).summary(true)', 'comments.limit(0).summary(true)',
          'created_time', 'ad_breaks', 'description', 'reactions.limit(0).summary(true)'
        ].join(',')
      end
    end

    # https://developers.facebook.com/docs/graph-api/reference/v2.10/video/video_insights
    def video_metrics
      %i(total_video_views total_video_views_unique total_video_avg_time_watched
      total_video_views_autoplayed total_video_views_clicked_to_play total_video_complete_views_auto_played
      total_video_complete_views_clicked_to_play total_video_views_sound_on total_video_10s_views_sound_on)
    end
  end
end
