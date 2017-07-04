package onlinemaths;

use strict; use warnings;

use JSON qw(decode_json);
use Data::Dumper;
use File::Find;
use List::Util qw(shuffle);
use File::Slurper qw(read_text);

use Dancer2;
use Dancer2::Session::Simple;
use Dancer2::Plugin::Passphrase;
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Captcha;
use Dancer2::FileUtils qw(path read_file_content);

$maths::VERSION = '0.01';

our $PAPERS;
our $PAGE_SIZE = 5;

hook before => sub {
    printf "logged in? %s\n", session('username') ? session('username') : '-';
    if ( !session('username')
         && request->dispatch_path !~ m{^/login}
         && request->dispatch_path !~ m{^/register}
         && request->dispatch_path !~ m{^/get_captcha}
         && request->dispatch_path !~ m{^/$}
        ) {
        forward '/login', { return_url => request->dispatch_path };
    }
};

get '/' => sub {
    template 'index';
};

get '/get_captcha' => sub {

    my $params = {
         new => {
             width   => 400,
             height  => 60,
             lines   => 1,
             gd_font => 'giant',
         },
         create   => [ normal => 'default' ],
         particle => [ 100 ],
         out      => { force => 'png' },
         random   => generate_captcha_keys(4),
    };

    return generate_captcha($params);
};

get '/register' => sub {
    template 'settings' => {
        form_title  => 'Register',
        form_action => '/register',
    };
};

get '/settings' => sub {

    my $username = session('username');
    my $user_row = database->quick_select('User', { username => $username });

    my $first_name = $user_row->{first_name};
    my $last_name  = $user_row->{last_name};

    template 'settings' => {
        form_title  => 'Settings',
        form_action => '/settings',
        first_name  => $first_name,
        last_name   => $last_name,
        username    => $username,
    };
};

post '/settings' => sub {

    my $c_username = session('username');
    my $first_name = params->{first_name};
    my $last_name  = params->{last_name};
    my $username   = params->{username};
    my $password   = params->{password};
    my $password2  = params->{password2};

    if (defined $username && defined $password) {
        if ($password eq $password2) {
            $password = passphrase($password)->generate;
            update_user($c_username, $username, $password->rfc2307(), $first_name, $last_name);

            session username => $username;
            if (is_admin_user($username)) {
                session is_admin => 1;
            }

            my $return_url = params->{return_url} || '/';
            print STDERR "Updated user [$username] ...\n";
            redirect '/';
        }
        else {
            template 'settings' => {
                error       => "Passwords did not match.",
                form_title  => 'Settings',
                form_action => '/settings',
                first_name  => $first_name,
                last_name   => $last_name,
                username    => $username,
                password    => $password,
            };
        }
    }
    else {
        template 'settings' => {
            error       => "Username and password required.",
            form_title  => 'Settings',
            form_action => '/settings',
            first_name  => $first_name,
            last_name   => $last_name,
            username    => $username,
            password    => $password,
        };
    }
};

post '/register' => sub {
    my $first_name = params->{first_name};
    my $last_name  = params->{last_name};
    my $username   = params->{username};
    my $password   = params->{password};

    if (defined $username && defined $password) {
        $password = passphrase($password)->generate;
        register_user($username, $password->rfc2307(), $first_name, $last_name);

        session username => $username;
        my $return_url = params->{return_url} || '/';
        print STDERR "Added user [$username] ...\n";
        redirect '/';
    }
    else {
        template 'settings' => {
            error       => "Username and password required.",
            form_title  => 'Register',
            form_action => '/register',
            first_name  => $first_name,
            last_name   => $last_name,
            username    => $username,
            password    => $password,
        };
    }
};

get  '/logout' => sub { context->destroy_session; redirect '/'; };
get  '/login'  => sub { template 'login' => { return_url => params->{return_url} }; };
post '/login'  => sub {
    my $p = request->params;

    unless (is_valid_captcha(request->params->{captcha})) {
        return template 'login' => {
            error    => "Invalid captcha",
            username => params->{username},
            password => params->{password}
        };
    }

    remove_captcha;

    if (is_valid_user(params->{username}, params->{password})) {
        session username => params->{username};
        if (is_admin_user(params->{username})) {
            session is_admin => 1;
        }

        my $return_url = params->{return_url} || '/';
        print STDERR "Redirecting to [$return_url] ...\n";
        redirect $return_url;
    }
    else {
        template 'login' => {
            error    => "Invalid username or password",
            username => params->{username},
            password => params->{password}
        };
    }
};

get '/passwords' => sub {
    my @users = database->quick_select('User', { is_admin => 0 });

    template 'passwords' => { users => \@users };
};

post '/passwords' => sub {
    my $user_id  = params->{user_id};
    my $password = params->{password};
    $password = passphrase($password)->generate;

    database->quick_update(
        'User', { id => $user_id }, { password => $password->rfc2307() }
    );

    redirect '/classes';
};

get '/rank' => sub {
    my $entries = get_scores();
    template 'rank' => { entries => $entries };
};

get '/scores' => sub {
    my $entries    = get_score_breakdowns();
    my $breakdowns = {
        entries => get_page_entries($entries),
    };
    my $total = scalar(@$entries);
    if ($total > $PAGE_SIZE) {
        $breakdowns->{next_page} = get_next_page_link($total, $PAGE_SIZE);
    }

    template 'scores' => $breakdowns;
};

get '/scores/:a/:b' => sub {
    my $entries = get_score_breakdowns();
    my $a = params->{a};
    my $b = params->{b};

    my $breakdowns = {
        entries => get_page_entries($entries, $a, $b),
    };

    my $total = scalar(@$entries);
    if ($total > $PAGE_SIZE) {
        if ($a >= $PAGE_SIZE) {
            $breakdowns->{prev_page} = get_prev_page_link($a);
        }
        if ($total > $b) {
            $breakdowns->{next_page} = get_next_page_link($total, $b);
        }
    }

    template 'scores' => $breakdowns;
};

get '/classes' => sub {

    my $dir = path(setting('appdir'), 'public', 'papers');
    build_tree(my $tree, $dir);
    $PAPERS = arrange_papers($dir, $tree);

    my $class      = $PAPERS->[0];
    my $categories = [];
    foreach (@{$class->{categories}}) {
        push @$categories, { name => $_->{name}, tag => $_->{tag} };
    }

    my $sub_cat_1 = [];
    my $sub_cat_2 = [];
    my $i = 1;
    foreach (@{$PAPERS->[0]->{categories}->[0]->{sub_categories}}) {
        if (exists $_->{papers}) {
            $_->{count} = ' (' . scalar(@{$_->{papers}}). ')';
        }
        if ($i <= 4) {
            push @$sub_cat_1, $_;
        }
        else {
            push @$sub_cat_2, $_;
        }
        $i++;
    }

    template 'classes' => {
        class_name     => $class->{name},
        class_tag      => $class->{tag},
        cat_name       => $categories->[0]->{name},
        cat_tag        => $categories->[0]->{tag},
        categories     => $categories,
        group1         => $sub_cat_1,
        group2         => $sub_cat_2,
    };
};

get '/classes/:class_tag' => sub {
    my $class_tag = params->{class_tag};
    my $selected_categories = list_categories($class_tag);
    my $categories = [];
    foreach (@$selected_categories) {
        push @$categories, { name => $_->{name}, tag => $_->{tag} };
    }

    my $sub_cat_1 = [];
    my $sub_cat_2 = [];
    my $i = 1;
    foreach (@{$categories->[0]->{sub_categories}}) {
        if (exists $_->{papers}) {
            $_->{count} = ' (' . scalar(@{$_->{papers}}). ')';
        }
        if ($i <= 4) {
            push @$sub_cat_1, $_;
        }
        else {
            push @$sub_cat_2, $_;
        }
        $i++;
    }

    template 'classes' => {
        class_name     => class_tag_to_name($class_tag),
        class_tag      => $class_tag,
        cat_name       => $categories->[0]->{name},
        cat_tag        => $categories->[0]->{tag},
        categories     => $categories,
        group1         => $sub_cat_1,
        group2         => $sub_cat_2,
    };
};

get '/classes/:class_tag/:category' => sub {
    my $class_tag = params->{class_tag};
    my $cat_tag   = params->{category};

    my $sub_categories = list_sub_categories($class_tag, $cat_tag);
    my $categories     = list_categories($class_tag);

    my $sub_cat_1 = [];
    my $sub_cat_2 = [];
    my $i = 1;

    foreach (@{$sub_categories}) {
        if (exists $_->{papers}) {
            $_->{count} = ' (' . scalar(@{$_->{papers}}). ')';
        }
        if ($i <= 4) {
            push @$sub_cat_1, $_;
        }
        else {
            push @$sub_cat_2, $_;
        }
        $i++;
    }

    template 'classes' => {
        class_name     => class_tag_to_name($class_tag),
        class_tag      => $class_tag,
        cat_name       => tag_to_name($cat_tag),
        cat_tag        => $cat_tag,
        categories     => $categories,
        group1         => $sub_cat_1,
        group2         => $sub_cat_2,
    };
};

get '/classes/:class_tag/:category/:sub_category' => sub {
    my $class_tag   = params->{class_tag};
    my $cat_tag     = params->{category};
    my $sub_cat_tag = params->{sub_category};

    my $paper      = get_random_paper($class_tag, $cat_tag, $sub_cat_tag);
    my $categories = list_categories($class_tag);
    my $paper_tag  = $paper->{tag};
    my $details    = get_paper($class_tag, $cat_tag, $sub_cat_tag, $paper_tag);
    $details->{categories}  = $categories;
    $details->{class_tag}   = $class_tag;
    $details->{cat_tag}     = $cat_tag;
    $details->{sub_cat_tag} = $sub_cat_tag;
    $details->{paper_tag}   = $paper_tag;

    template 'paper' => $details;
};

post '/classes/:class_tag/:category/:sub_category' => sub {
    my $class_tag   = params->{class_tag};
    my $cat_tag     = params->{category};
    my $sub_cat_tag = params->{sub_category};
    my $paper_tag   = params->{paper_tag};
    my $user_id     = params->{user_id};
    my $score       = params->{score};

    save_score($class_tag, $cat_tag, $sub_cat_tag, $paper_tag, $user_id, $score);
    redirect "/classes/$class_tag/$cat_tag";
};

get '/classes/:class_tag/:category/:sub_category/:paper/edit-paper' => sub {
    my $class_tag    = params->{class_tag};
    my $category     = params->{category};
    my $sub_category = params->{sub_category};
    my $paper_tag    = params->{paper};

    my $data   = get_paper_content($class_tag, $category, $sub_category, $paper_tag);
    my $paper  = {
        class_tag         => $class_tag,
        class_name        => class_tag_to_name($class_tag),
        category_tag      => $category,
        category_name     => tag_to_name($category),
        sub_category_tag  => $sub_category,
        sub_category_name => tag_to_name($sub_category),
        paper_tag         => $paper_tag,
        paper_name        => paper_tag_to_name($paper_tag),
        data              => $data,
    };

    template 'add_paper' => $paper;
};

post '/classes/:class_tag/:category/:sub_category/:paper/edit-paper' => sub {
    my $data         = params->{data};
    my $class_tag    = params->{class_tag};
    my $category     = params->{category};
    my $sub_category = params->{sub_category};
    my $paper_tag    = params->{paper};

    my $paper = {
        class_tag         => $class_tag,
        class_name        => class_tag_to_name($class_tag),
        category_tag      => $category,
        category_name     => tag_to_name($category),
        sub_category_tag  => $sub_category,
        sub_category_name => tag_to_name($sub_category),
        paper_tag         => $paper_tag,
        paper_name        => paper_tag_to_name($paper_tag),
    };

    eval { decode_json($data) };
    if ($@) {
        $paper->{error} = $@;
        $paper->{data}  = $data;
        template 'add_paper' => $paper;
    }
    else {
        update_paper($class_tag, $category, $sub_category, $paper_tag, $data);
        redirect "/classes/$class_tag/$category";
    }
};

get '/classes/:class_tag/:category/:sub_category/add-paper' => sub {
    my $papers = list_papers(params->{class_tag}, params->{category}, params->{sub_category});

    my $paper  = {
        class_tag         => params->{class_tag},
        class_name        => class_tag_to_name(params->{class_tag}),
        category_tag      => params->{category},
        category_name     => tag_to_name(params->{category}),
        sub_category_tag  => params->{sub_category},
        sub_category_name => tag_to_name(params->{sub_category}),
    };

    template 'add_paper' => $paper;
};

post '/classes/:class_tag/:category/:sub_category/add-paper' => sub {
    my $data         = params->{data};
    my $class_tag    = params->{class_tag};
    my $category     = params->{category};
    my $sub_category = params->{sub_category};

    my $papers = {
        class_tag         => $class_tag,
        class_name        => class_tag_to_name($class_tag),
        category_tag      => $category,
        category_name     => tag_to_name($category),
        sub_category_tag  => $sub_category,
        sub_category_name => tag_to_name($sub_category),
    };

    eval { decode_json($data) };
    if ($@) {
        $papers->{error} = $@;
        $papers->{data}  = $data;
        template 'add_paper' => $papers;
    }
    else {
        add_paper($class_tag, $category, $sub_category, $data);
        redirect "/classes/$class_tag/$category";
    }
};

get '/classes/:class_tag/:category/:sub_category/:paper' => sub {
    my $paper = get_paper(params->{class_tag}, params->{category}, params->{sub_category}, params->{paper});
    $paper->{class_tag}         = params->{class_tag};
    $paper->{class_name}        = class_tag_to_name(params->{class_tag});
    $paper->{category_tag}      = params->{category};
    $paper->{category_name}     = tag_to_name(params->{category});
    $paper->{sub_category_tag}  = params->{sub_category};
    $paper->{sub_category_name} = tag_to_name(params->{sub_category});
    $paper->{paper_name}        = paper_tag_to_name(params->{paper});
    template 'paper' => $paper;
};

post '/classes/:class_tag/:category/:sub_category/:paper' => sub {
    save_score(params->{class_tag}, params->{category}, params->{sub_category}, params->{paper}, params->{user_id}, params->{percentage});

    my $paper = get_paper(params->{class_tag}, params->{category}, params->{sub_category}, params->{paper});
    $paper->{class_tag}         = params->{class_tag};
    $paper->{class_name}        = class_tag_to_name(params->{class_tag});
    $paper->{category_tag}      = params->{category};
    $paper->{category_name}     = tag_to_name(params->{category});
    $paper->{sub_category_tag}  = params->{sub_category};
    $paper->{sub_category_name} = tag_to_name(params->{sub_category});
    $paper->{paper_name}        = paper_tag_to_name(params->{paper});
    template 'paper' => $paper;
};

#
#
# METHODS

sub get_prev_page_link {
    my ($a) = @_;

    if ($a - $PAGE_SIZE <= 0) {
        $a = 1;
        $b = $PAGE_SIZE;
    }
    else {
        $b = $a;
        $a = $a - $PAGE_SIZE;
    }

    return sprintf("/scores/%d/%d", $a, $b);
}

sub get_next_page_link {
    my ($total, $b) = @_;

    if ($total > ($b + $PAGE_SIZE)) {
        $a = $b;
        $b = $a + $PAGE_SIZE;
    }
    else {
        $a = $b;
        $b = $b + $PAGE_SIZE;
    }

    return sprintf("/scores/%d/%d", $a, $b);
}

sub get_page_entries {
    my ($entries, $a, $b) = @_;

    $a = 1 unless defined $a;
    $a++ if ($a > 1);
    $b = ($a + $PAGE_SIZE) - 1 unless defined $b;
    if ($b - $a > $PAGE_SIZE) {
        $b = ($a + $PAGE_SIZE) - 1;
    }


    my $page = [];
    my $i = 1;
    foreach (@$entries) {
        if ($i >= $a && $i <= $b) {
            push @$page, $_;
        }
        $i++;
    }

    return $page;
}

sub get_score_breakdowns {

    my $user_id    = get_logged_user();
    my @activities = database->quick_select('Activity', { user_id => $user_id });

    my $reports = {};
    foreach my $activity (@activities) {
        my $date         = $activity->{activity_date};
        my $class        = $activity->{class};
        my $category     = $activity->{category};
        my $sub_category = $activity->{sub_category};
        my $paper        = $activity->{paper};
        my $score        = $activity->{score};

        $reports->{$date}->{$class}->{$category}->{$sub_category}->{$paper} = $score;
    }

    my $index = 1;
    my $breakdowns = [];
    foreach my $date (reverse sort keys %$reports) {
        foreach my $class (sort keys %{$reports->{$date}}) {
            foreach my $category (sort keys %{$reports->{$date}->{$class}}) {
                foreach my $sub_category (sort keys %{$reports->{$date}->{$class}->{$category}}) {
                    foreach my $paper (sort keys %{$reports->{$date}->{$class}->{$category}->{$sub_category}}) {
                        push @$breakdowns, {
                            s_no         => $index++,
                            date         => $date,
                            class        => class_tag_to_name($class),
                            category     => tag_to_name($category),
                            sub_category => tag_to_name($sub_category),
                            paper        => paper_tag_to_name($paper),
                            score        => $reports->{$date}->{$class}->{$category}->{$sub_category}->{$paper},
                        };
                    }
                }
            }
        }
    }

    return $breakdowns;
}

sub get_scores {

    my @activities = database->quick_select('Activity', {});
    my @users = database->quick_select('User', { is_admin => 0 });

    my $scores  = {};
    my $attempt = {};
    foreach my $activity (@activities) {
        $scores->{$activity->{user_id}}  += $activity->{score};
        $attempt->{$activity->{user_id}} += 1;
    }

    my $avg_scores = {};
    my $user_names = {};
    foreach my $user (@users) {
        my $user_id = $user->{id};
        next unless (exists $scores->{$user_id});
        $user_names->{$user_id} = sprintf("%s %s", $user->{first_name}, $user->{last_name});
        $avg_scores->{$user_id} = sprintf("%.02f", ($scores->{$user_id}/$attempt->{$user_id}));
    }

    my $entries = [];
    my $rank = 1;
    foreach my $user_id (sort { $avg_scores->{$b} <=> $avg_scores->{$a} } keys %$avg_scores) {
        push @{$entries}, {
            rank => $rank++,
            name => $user_names->{$user_id},
            activities_count => $attempt->{$user_id},
            average_score => $avg_scores->{$user_id},
        };
    }

    return $entries;
}

sub save_score {
    my ($class, $category, $sub_category, $paper, $user_id, $score) = @_;

    database->quick_insert('Activity', {
        user_id      => $user_id,
        class        => $class,
        category     => $category,
        sub_category => $sub_category,
        paper        => $paper,
        score        => $score
    });
}

sub list_classes {

    if (!defined $PAPERS) {
        my $dir = path(setting('appdir'), 'public', 'papers');
        build_tree(my $tree, $dir);
        $PAPERS = arrange_papers($dir, $tree);
    }

    my $classes = [];
    foreach my $year (@$PAPERS) {
        push @{$classes}, { name => $year->{name}, tag => $year->{tag} };
    }

    return { classes => $classes };
}

sub list_categories {
    my ($year) = @_;

    if (!defined $PAPERS) {
        my $dir = path(setting('appdir'), 'public', 'papers');
        build_tree(my $tree, $dir);
        $PAPERS = arrange_papers($dir, $tree);
    }

    my $categories = [];
    foreach (@$PAPERS) {
        if ($year eq $_->{tag}) {
            $categories = $_->{categories};
            last;
        }
    }

    foreach (@$categories) {
        $_->{class_tag} = $year;
    }

    return $categories;
}

sub list_sub_categories {
    my ($class_tag, $category) = @_;

    if (!defined $PAPERS) {
        my $dir = path(setting('appdir'), 'public', 'papers');
        build_tree(my $tree, $dir);
        $PAPERS = arrange_papers($dir, $tree);
    }

    my $sub_categories = [];
    foreach my $p (@$PAPERS) {
        if ($class_tag eq $p->{tag}) {
            my $categories = $p->{categories};
            foreach my $c (@$categories) {
                if ($category eq $c->{tag}) {
                    $sub_categories = $c->{sub_categories};
                    last;
                }
            }
        }
    }

    foreach (@$sub_categories) {
        $_->{class_tag} = $class_tag;
        $_->{category}  = $category;
    }

    return $sub_categories;
}

sub update_paper {
    my ($class_tag, $category, $sub_category, $paper, $data) = @_;

    my $file = path(setting('appdir'), 'public', 'papers', $class_tag, $category, $sub_category, "${paper}.json");
    open my $F, ">$file";
    print $F $data;
    close $F;

    my $dir = path(setting('appdir'), 'public', 'papers');
    build_tree(my $tree, $dir);
    $PAPERS = arrange_papers($dir, $tree);

    sort_papers($class_tag, $category, $sub_category, $PAPERS);
}

sub add_paper {
    my ($class_tag, $category, $sub_category, $data) = @_;

    my $paper_tag = get_next_paper_tag($class_tag, $category, $sub_category);
    save_paper($class_tag, $category, $sub_category, $paper_tag, $data);

    my $dir = path(setting('appdir'), 'public', 'papers');
    build_tree(my $tree, $dir);
    $PAPERS = arrange_papers($dir, $tree);

    sort_papers($class_tag, $category, $sub_category, $PAPERS);
}

sub get_random_paper {
    my ($class_tag, $category, $sub_category) = @_;

    if (!defined $PAPERS) {
        my $dir = path(setting('appdir'), 'public', 'papers');
        build_tree(my $tree, $dir);
        $PAPERS = arrange_papers($dir, $tree);
    }

    my $all_papers = [];
    foreach my $p (@$PAPERS) {
        if ($class_tag eq $p->{tag}) {
            my $categories = $p->{categories};
            foreach my $c (@$categories) {
                if ($category eq $c->{tag}) {
                    my $sub_categories = $c->{sub_categories};
                    foreach my $s (@$sub_categories) {
                        if ($sub_category eq $s->{tag}) {
                            $all_papers = $s->{papers};
                            last;
                        }
                    }
                }
            }
        }
    }

    foreach (@$all_papers) {
        $_->{class_tag}     = $class_tag;
        $_->{category}      = $category;
        $_->{sub_category}  = $sub_category;
    }

    my @random_papers = shuffle @$all_papers;

    return $random_papers[0];
}

sub get_paper_content {
    my ($class_tag, $category, $sub_category, $paper) = @_;

    my $file = path(setting('appdir'), 'public', 'papers', $class_tag, $category, $sub_category, "${paper}.json");

    return read_text($file);
}


sub save_paper {
    my ($class_tag, $category, $sub_category, $paper_tag, $data) = @_;

    my $dir = path(setting('appdir'), 'public', 'papers', $class_tag, $category, $sub_category);
    open my $d, ">$dir/$paper_tag";
    print $d $data;
    close $d;
}

sub get_next_paper_tag {
    my ($class_tag, $category, $sub_category) = @_;

    my $dir = path(setting('appdir'), 'public', 'papers', $class_tag, $category, $sub_category);
    my @papers;
    opendir(my $dh, $dir);
    while (my $paper = readdir $dh) {
        if ($paper eq '.' or $paper eq '..') {
            next;
        }
        push @papers, $paper;
    }
    closedir($dh);

    @papers = reverse sort @papers;

    my $paper_tag = $papers[0];
    $paper_tag =~ s/(\d+)(.*)/$2/;
    my $paper_num = $1;

    return sprintf("%02d%s", ++$paper_num, $paper_tag);
}

sub list_papers {
    my ($class_tag, $category, $sub_category) = @_;

    if (!defined $PAPERS) {
        my $dir = path(setting('appdir'), 'public', 'papers');
        build_tree(my $tree, $dir);
        $PAPERS = arrange_papers($dir, $tree);
    }


    return { rows => sort_papers($class_tag, $category, $sub_category, $PAPERS) };
}

sub sort_papers {
    my ($class_tag, $category, $sub_category, $papers) = @_;

    my $all_papers = [];
    foreach my $p (@$papers) {
        if ($class_tag eq $p->{tag}) {
            my $categories = $p->{categories};
            foreach my $c (@$categories) {
                if ($category eq $c->{tag}) {
                    my $sub_categories = $c->{sub_categories};
                    foreach my $s (@$sub_categories) {
                        if ($sub_category eq $s->{tag}) {
                            $all_papers = $s->{papers};
                            last;
                        }
                    }
                }
            }
        }
    }

    my $sorted_papers = [];
    my $row = [];
    my $r = 1;
    my $c = 1;
    foreach (@$all_papers) {
        $_->{class_tag}     = $class_tag;
        $_->{category}      = $category;
        $_->{sub_category}  = $sub_category;
        push @$row, $_;

        $c++;
        if ($c == 2) {
            push @$sorted_papers, $row;
            $r++;
            $c   = 1;
            $row = [];
        }
    }

    return $sorted_papers;
}

sub class_tag_to_name {
    my ($class_tag) = @_;

    my $class_name = $class_tag;
    $class_name =~ s/(\d+)(\-)(.*)$/$3/;
    $class_name =~ s/^\s+//g;
    $class_name =~ s/\s+$//g;
    my $class_number = $1;

    return sprintf("%s %d", ucfirst($class_name), $class_number);
}

sub paper_tag_to_name {
    my ($paper_tag) = @_;

    my $paper_name = $paper_tag;
    $paper_name =~ s/(\d+)(\-)(.*)$/$3/;
    $paper_name =~ s/^\s+//g;
    $paper_name =~ s/\s+$//g;
    $paper_name = join (" ", map { ucfirst(lc($_)) } split /\-/, $paper_name);
    my $paper_number = $1;

    return sprintf("%s %d", ucfirst($paper_name), $paper_number);
}

sub tag_to_name {
    my ($tag) = @_;

    my $name = $tag;
    $name =~ s/(\d+\-)(.*)$/$2/;
    $name = join (" ", map { ucfirst(lc($_)) } split /\-/, $name);

    return $name;
}

sub arrange_papers {
    my ($dir, $tree) = @_;

    my $classes = [];
    foreach my $class (sort keys %{$tree->{$dir}}) {
        my $class_name = class_tag_to_name($class);
        my $categories = [];
        foreach my $cat (sort keys %{$tree->{$dir}->{$class}}) {
            my $cat_name = tag_to_name($cat);
            my $category = {
                tag => $cat,
                name => $cat_name,
            };

            foreach my $subcat (sort keys %{$tree->{$dir}->{$class}->{$cat}}) {
                my $subcat_name  = tag_to_name($subcat);
                my $sub_category = {
                    tag  => $subcat,
                    name => $subcat_name,
                };

                foreach my $paper (sort keys %{$tree->{$dir}->{$class}->{$cat}->{$subcat}}) {
                    $paper =~ s/(.*)\.json/$1/;
                    my $paper_name = paper_tag_to_name($paper);
                    push @{$sub_category->{papers}}, { tag => $paper, name => $paper_name };
                }

                push @{$category->{sub_categories}}, $sub_category;
            }

            push @$categories, $category;
        }

        push @$classes, { tag => $class, name => $class_name, categories => $categories };
    }

    return $classes;
}

sub build_tree {
    my $node = $_[0] = {};
    my @s;

    find(
        sub {
            $node = (pop @s)->[1] while @s and $File::Find::dir ne $s[-1][0];
            return $node->{$_} = -s if -f;
            push @s, [ $File::Find::name, $node ];
            $node = $node->{$_} = {};
        }, $_[1]);

    $_[0]{$_[1]} = delete $_[0]{'.'};
}

sub is_valid_user {
    my ($username, $password) = @_;

    my $user = database->quick_select('User', { username => $username });
    return 0 unless defined $user;

    return (passphrase($password)->matches($user->{password}));
}

sub is_admin_user {
    my ($username) = @_;

    my $user = database->quick_select('User', { username => $username });
    return 0 unless defined $user;

    return ($user->{is_admin} == 1);
}

sub register_user {
    my ($username, $password, $first_name, $last_name) = @_;

    database->quick_insert('User', {
        username   => $username,
        password   => $password,
        first_name => $first_name,
        last_name  => $last_name,
    });
}

sub update_user {
    my ($c_username, $username, $password, $first_name, $last_name) = @_;

    my $user_row = database->quick_select('User', { username => $c_username });
    my $user_id  = $user_row->{id};

    database->quick_update(
        'User',
        { id => $user_id },
        { username   => $username,
          password   => $password,
          first_name => $first_name,
          last_name  => $last_name,
        });
}

sub randomise {
    my ($entries) = @_;

    my $hash = {};
    my $i = 1;
    foreach my $entry (@$entries) {
        $hash->{$i++} = $entry;
    }

    my @keys = keys %$hash;
    my @random = ();
    foreach (shuffle(@keys)) {
        push @random, $hash->{$_};
    }

    return @random;
}

sub get_logged_user {
    my $username = session('username');
    return unless defined $username;

    my $user = database->quick_select('User', { username => $username });
    return $user->{id};
}

sub get_paper {
    my ($class_tag, $category, $sub_category, $paper) = @_;

    my $user_id = get_logged_user();
    my $file    = read_file_content(path(setting('appdir'), 'public', 'papers', $class_tag, $category, $sub_category, "${paper}.json"));
    my $data    = JSON->new->allow_nonref->utf8(1)->decode($file);

    my $title = $category;
    $title =~ s/(\d+\-)(.*)$/$2/;
    $title = join (" ", map { ucfirst(lc($_)) } split /\-/, $title);

    my $sub_title = $sub_category;
    $sub_title =~ s/(\d+\-)(.*)$/$2/;
    $sub_title = join (" ", map { ucfirst(lc($_)) } split /\-/, $sub_title);

    my $entries   = $data->{entries};
    my $questions = [];
    my $answers   = [];
    foreach my $entry (randomise($entries)) {

        push @$answers, {
            id    => '"q' . $entry->{id} . '"',
            value => $entry->{answer},
        };

        my $question = {
            id         => $entry->{id},
            desc       => $entry->{desc},
            image_name => 'q' . $entry->{id} .'_image',
        };

        my $letter = 'a';
        foreach my $choice (@{$entry->{choices}}) {
            push @{$question->{choices}}, {
                'choice_name'  => 'q'. $entry->{id},
                'choice_value' => $letter++,
                'choice_text'  => $choice,
            };
        }

        push @$questions, $question;
    }

    return {
        user_id         => $user_id,
        title           => $title,
        sub_title       => $sub_title,
        question_counts => scalar(@$questions),
        questions       => $questions,
        answers         => $answers,
    };
}

sub generate_captcha_keys {
    my ($count) = @_;

    my @chars = (0..9);
    my $min   = 1;
    my $max   = scalar(@chars);

    my $random = '';
    foreach (1..$count) {
        $random .= $chars[int($min + rand($max - $min))];
    }

    return $random;
}

1;
