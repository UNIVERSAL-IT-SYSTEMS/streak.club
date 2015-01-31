
lapis = require "lapis"
db = require "lapis.db"

import
  respond_to, capture_errors, assert_error, capture_errors_json
  from require "lapis.application"

import assert_valid from require "lapis.validate"
import trim_filter, slugify from require "lapis.util"

import Users, Uploads, Submissions, Streaks, StreakUsers from require "models"

import not_found, require_login, assert_page from require "helpers.app"
import assert_csrf from require "helpers.csrf"
import render_submissions_page from require "helpers.submissions"

SUBMISSION_PER_PAGE = 5

find_user = =>
  @user = if @params.id
    assert_valid @params, {
      {"id", is_integer: true}
    }
    Users\find @params.id
  elseif @params.slug
    Users\find slug: slugify @params.slug

  assert_error @user, "invalid user"

class UsersApplication extends lapis.Application
  [user_profile: "/u/:slug"]: capture_errors {
    on_error: => not_found
    =>
      find_user @
      assert_page @

      @user_profile = @user\get_user_profile!

      pager = @user\find_submissions {
        per_page: SUBMISSION_PER_PAGE
        prepare_results: (...) ->
          Submissions\preload_for_list ..., {
            likes_for: @current_user
          }
      }

      @submissions = pager\get_page @page

      if @params.format == "json"
        return render_submissions_page @, SUBMISSION_PER_PAGE

      @title = @user\name_for_display!
      @has_more = @user.submissions_count > SUBMISSION_PER_PAGE

      @following = @user\followed_by @current_user

      with_streak_users = (streaks) ->
        Users\include_in streaks, "user_id"
        StreakUsers\include_in streaks, "streak_id", flip: true, where: {
          user_id: @user.id
        }
        streaks

      @active_streaks = @user\find_participating_streaks({
        publish_status: "published"
        state: "active"
        prepare_results: with_streak_users
      })\get_page!

      @upcoming_streaks = @user\find_participating_streaks({
        publish_status: "published"
        state: "upcoming"
        prepare_results: with_streak_users
      })\get_page!

      @completed_streaks = @user\find_participating_streaks({
        publish_status: "published"
        state: "completed"
        prepare_results: with_streak_users
      })\get_page!

      for streaks in *{@active_streaks, @completed_streaks}
        for streak in *streaks
          continue unless streak.streak_user
          streak.streak_user.streak = streak
          streak.completed_units = streak.streak_user\get_completed_units!

      render: true
  }

  [user_following: "/u/:slug/following"]: capture_errors {
    on_error: => not_found
    =>
      import Followings from require "models"

      find_user @
      assert_page @
      @pager = @user\find_following per_page: 25
      @users = @pager\get_page @page
      Followings\load_for_users @users, @current_user

      @title = "Followed by #{@user\name_for_display!}"
      if @page > 1
        @title ..= " - Page #{@page}"

      render: true
  }

  [user_followers: "/u/:slug/followers"]: capture_errors {
    on_error: => not_found
    =>
      import Followings from require "models"
      find_user @
      assert_page @

      @pager = @user\find_followers per_page: 25
      @users = @pager\get_page @page
      Followings\load_for_users @users, @current_user

      @title = "#{@user\name_for_display!}'s followers"
      if @page > 1
        @title ..= " - Page #{@page}"

      render: true
  }

  [user_streaks_hosted: "/u/:slug/streaks-hosted"]: capture_errors {
    on_error: => not_found
    =>
      find_user @
      assert_page @

      @pager = @user\find_hosted_streaks status: "published"
      @streaks = @pager\get_page @page

      render: true
  }


  [user_register: "/register"]: respond_to {
    before: =>
      if @current_user
        @write redirect_to: @url_for "index"

    GET: => render: true

    POST: capture_errors =>
      assert_csrf @
      trim_filter @params

      assert_valid @params, {
        { "username", exists: true, min_length: 2, max_length: 25 }
        { "password", exists: true, min_length: 2 }
        { "password_repeat", equals: @params.password }
        { "email", exists: true, min_length: 3 }
        { "accept_terms", equals: "yes", "You must accept the Terms of Service" }
      }

      assert_error @params.email\match(".@."), "invalid email address"

      user = assert_error Users\create {
        username: @params.username
        email: @params.email
        password: @params.password
      }

      user\write_session @

      @session.flash = "Welcome to streak.club!"
      redirect_to: @url_for "index"
  }

  [user_login: "/login"]: respond_to {
    before: =>
      if @current_user
        @write redirect_to: @url_for "index"

    GET: => render: true
    POST: capture_errors =>
      assert_csrf @
      assert_valid @params, {
        { "username", exists: true }
        { "password", exists: true }
      }

      user = assert_error Users\login @params.username, @params.password
      user\write_session @

      @session.flash = "Welcome back!"
      redirect_to: @params.return_to or @url_for("index")
  }

  [user_logout: "/logout"]: =>
    @session.user = false
    @session.flash = "You are logged out"
    redirect_to: "/"

  [user_settings: "/user/settings"]: require_login respond_to {
    before: =>
      @user = @current_user
      @user_profile = @user\get_user_profile!

    GET: =>
      render: true

    POST: capture_errors_json =>
      assert_csrf @
      assert_valid @params, {
        {"user", type: "table"}
        {"user_profile", type: "table"}
      }

      user_update = @params.user
      trim_filter user_update, {"display_name"}

      assert_valid user_update, {
        {"display_name", optional: true, max_length: 120}
      }

      user_update.display_name or= db.NULL
      @user\update user_update

      profile_update = @params.user_profile
      trim_filter profile_update, {"website", "twitter", "bio"}, db.NULL

      assert_valid profile_update, {
        {"bio", optional: true, max_length: 1024*1024}
      }

      @user\get_user_profile!\update profile_update

      @session.flash = "Profile updated"
      redirect_to: @url_for "user_settings"
  }

  [user_follow: "/user/:id/follow"]: require_login capture_errors_json =>
    find_user @
    assert_csrf @
    assert_error @current_user.id != @user.id, "invalid user"

    import Followings, Notifications from require "models"
    following = Followings\create {
      source_user_id: @current_user.id
      dest_user_id: @user.id
    }

    if following
      Notifications\notify_for @user, @current_user, "follow"

    json: { success: not not following }

  [user_unfollow: "/user/:id/unfollow"]: require_login capture_errors_json =>
    find_user @
    assert_csrf @
    assert_error @current_user.id != @user.id, "invalid user"

    import Followings, Notifications from require "models"

    params = {
      source_user_id: @current_user.id
      dest_user_id: @user.id
    }

    success = if f = Followings\find params
      f\delete!
      Notifications\undo_notify @user, @current_user, "follow"
      true

    json: { success: success or false }

