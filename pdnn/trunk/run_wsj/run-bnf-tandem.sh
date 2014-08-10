#!/bin/bash

# Apache 2.0
# This script trains tandem systems on top of bottleneck features. It is to 
# be run after run.sh. Before  running  this, you  should already build the 
# initial GMM model. This script requires a  GPU, and also the "pdnn" tool-
# kit to train the BNF network.

# For more informaiton regarding the recipes and results, visit our webiste
# http://www.cs.cmu.edu/~ymiao/kaldipdnn

working_dir=exp_pdnn/bnf_tandem
do_ptr=true  # whether to do pre-training
delete_pfile=false # whether to delete pfiles after DNN training

gmmdir=exp/tri4b

# Specify the gpu device to be used
gpu=gpu

# You can also specify the directory for bnf network generated from another
# recipe, e.g, run-bnf-dnn.sh
bnf_dir=

cmd=run.pl
. cmd.sh
[ -f path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

if [ ! -z $bnf_dir ]; then 
  if [ ! -f $bnf_dir/bnf.nnet ]; then 
     echo "You specify bnf_dir but bnf.nnet cannot be found there."
     exit 1
  else
     cp $bnf_dir/bnf.nnet $working_dir
     ( cd $working_dir; touch {train,valid}.pfile.done bnf.{ptr,fine}.done; )
  fi
fi 

# At this point you may want to make sure the directory $working_dir is
# somewhere with a lot of space, preferably on the local GPU-containing machine.
if [ ! -d pdnn ]; then
  echo "Checking out PDNN code."
  svn co svn://svn.code.sf.net/p/kaldipdnn/code-0/pdnn pdnn
fi

if [ ! -d steps_pdnn ]; then
  echo "Checking out steps_pdnn scripts."
  svn co svn://svn.code.sf.net/p/kaldipdnn/code-0/trunk/steps_pdnn steps_pdnn
fi

if ! nvidia-smi; then
  echo "The command nvidia-smi was not found: this probably means you don't have a GPU."
  echo "(Note: this script might still work, it would just be slower.)"
fi

# The hope here is that Theano has been installed either to python or to python2.6
pythonCMD=python
if ! python -c 'import theano;'; then
  if ! python2.6 -c 'import theano;'; then
    echo "Theano does not seem to be installed on your machine.  Not continuing."
    echo "(Note: this script might still work, it would just be slower.)"
    exit 1;
  else
    pythonCMD=python2.6
  fi
fi

mkdir -p $working_dir/log

! gmm-info $gmmdir/final.mdl >&/dev/null && \
   echo "Error getting GMM info from $gmmdir/final.mdl" && exit 1;

num_pdfs=`gmm-info $gmmdir/final.mdl | grep pdfs | awk '{print $NF}'` || exit 1;

echo ---------------------------------------------------------------------
echo "Generate alignment and prepare fMLLR features"
echo ---------------------------------------------------------------------
# Alignment on the training and validation data
if [ ! -d ${gmmdir}_ali ]; then
  echo "Generate alignment on train_si284"
  steps/align_fmllr.sh --nj 24 --cmd "$train_cmd" \
    data/train_si284 data/lang $gmmdir ${gmmdir}_ali || exit 1
fi

# Dump fMLLR features. We generate "fake" cmvn states (0 means and 1 variance) which apply no normalization 
if [ ! -d $working_dir/data/train_si284 ]; then
  echo "Save fmllr features of train_si284"
  steps/make_fmllr_feats.sh --nj 10 --cmd "$train_cmd" \
    --transform-dir ${gmmdir}_ali \
    $working_dir/data/train_si284 data/train_si284 $gmmdir $working_dir/_log $working_dir/_fmllr || exit 1
  steps/compute_cmvn_stats.sh --fake \
    $working_dir/data/train_si284 $working_dir/_log $working_dir/_fmllr || exit 1;
fi
if [ ! -d $working_dir/data/test_dev93 ]; then
  echo "Save fmllr features of test_dev93"
  steps/make_fmllr_feats.sh --nj 10 --cmd "$train_cmd" \
    --transform-dir $gmmdir/decode_bd_tgpr_dev93 \
    $working_dir/data/test_dev93 data/test_dev93 $gmmdir $working_dir/_log $working_dir/_fmllr || exit 1
  steps/compute_cmvn_stats.sh --fake \
    $working_dir/data/test_dev93 $working_dir/_log $working_dir/_fmllr || exit 1;
fi
if [ ! -d $working_dir/data/test_eval92 ]; then
  echo "Save fmllr features of test_eval92"
  steps/make_fmllr_feats.sh --nj 8 --cmd "$train_cmd" \
    --transform-dir $gmmdir/decode_bd_tgpr_eval92 \
    $working_dir/data/test_eval92 data/test_eval92 $gmmdir $working_dir/_log $working_dir/_fmllr || exit 1
  steps/compute_cmvn_stats.sh --fake \
    $working_dir/data/test_eval92 $working_dir/_log $working_dir/_fmllr || exit 1;
fi

echo ---------------------------------------------------------------------
echo "Create DNN training and validation pfiles"
echo ---------------------------------------------------------------------

# By default, DNN inputs include: spliced 11 frames (+/-5) of fMLLR with 440 dimensions
if [ ! -f $working_dir/train.pfile.done ]; then
  steps_pdnn/build_nnet_pfile.sh --cmd "$train_cmd" --every-nth-frame 1 --norm-vars false \
    --do-split true --pfile-unit-size 30 --cv-ratio 0.05 \
    --splice-opts "--left-context=5 --right-context=5" --input-dim 440 \
    $working_dir/data/train_si284 ${gmmdir}_ali $working_dir || exit 1
  ( cd $working_dir; rm concat.pfile; )
  touch $working_dir/train.pfile.done
fi

# The scripts up to now are the same as run-dnn.sh. Pfile generation can be very expensive. You may 
# want to reuse Pfiles generated by run-dnn.sh. Link Pfiles generated there to $working_dir and also
# touch $working_dir/train.pfile.done

echo ---------------------------------------------------------------------
echo "Train BNF network"
echo ---------------------------------------------------------------------
feat_dim=$(cat $working_dir/train.pfile |head |grep num_features| awk '{print $2}') || exit 1;

if $do_ptr && [ ! -f $working_dir/bnf.ptr.done ]; then
  echo "SDA Pre-training"
  $cmd $working_dir/log/bnf.ptr.log \
    export PYTHONPATH=$PYTHONPATH:`pwd`/pdnn/ \; \
    export THEANO_FLAGS=mode=FAST_RUN,device=$gpu,floatX=float32 \; \
    $pythonCMD pdnn/run_SdA.py --train-data "$working_dir/train.pfile,partition=2000m,random=true,stream=true" \
                          --nnet-spec "$feat_dim:1024:1024:1024:1024:42:1024:$num_pdfs" \
                          --first-reconstruct-activation "tanh" \
                          --wdir $working_dir --output-file $working_dir/bnf.ptr \
                          --ptr-layer-number 4 --epoch-number 5 || exit 1;
  touch $working_dir/bnf.ptr.done
fi

if [ ! -f $working_dir/bnf.fine.done ]; then
  echo "Fine-tuning DNN"
  $cmd $working_dir/log/bnf.fine.log \
    export PYTHONPATH=$PYTHONPATH:`pwd`/ptdnn/ \; \
    export THEANO_FLAGS=mode=FAST_RUN,device=$gpu,floatX=float32 \; \
    $pythonCMD pdnn/run_DNN.py --train-data "$working_dir/train.pfile,partition=2000m,random=true,stream=true" \
                          --valid-data "$working_dir/valid.pfile,partition=600m,random=true,stream=true" \
                          --nnet-spec "$feat_dim:1024:1024:1024:1024:42:1024:$num_pdfs" \
                          --ptr-file $working_dir/bnf.ptr --ptr-layer-number 4 \
                          --output-format kaldi --lrate "D:0.08:0.5:0.2,0.2:8" \
                          --wdir $working_dir --output-file $working_dir/bnf.nnet || exit 1;
  touch $working_dir/bnf.fine.done
  $delete_pfile && rm -rf $working_dir/*.pfile
fi

echo ---------------------------------------------------------------------
echo "Generate bottleneck features"
echo ---------------------------------------------------------------------
for set in train_si284 test_dev93 test_eval92; do
  if [ ! -d $working_dir/data_bnf/${set} ]; then
    echo "Save BNF features of $set"
    steps_pdnn/make_bnf_feat.sh --nj 8 --cmd "$train_cmd" --norm-vars false \
      $working_dir/data_bnf/${set} $working_dir/data/${set} $working_dir $working_dir/_log $working_dir/_bnf || exit 1
    # We will normalize BNF features, thus are not providing --fake here. Intuitively, apply CMN over BNF features 
    # might be redundant. But our experiments on WSJ show gains by doing this.
    steps/compute_cmvn_stats.sh \
      $working_dir/data_bnf/${set} $working_dir/_log $working_dir/_bnf || exit 1;
  fi
done

datadir=$working_dir/data_bnf

echo ---------------------------------------------------------------------
echo "Build LDA+MLLT and MMI systems over bottleneck features"
echo ---------------------------------------------------------------------
decode_param="--beam 15.0 --latbeam 7.0 --acwt 0.04" # Note the decoding 
                                   # parameters differ from MFCC systems
scoring_opts="--min-lmwt 26 --max-lmwt 34"
denlats_param="--acwt 0.05"   # Parameters for lattice generation

if [ ! -f $working_dir/lda.mllt.done ]; then
  echo "Training LDA+MLLT"
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    4200 40000 $datadir/train_si284 data/lang ${gmmdir}_ali $working_dir/tri5a || exit 1;

  echo "Decoding LDA+MLLT"
  graph_dir=$working_dir/tri5a/graph_bd_tgpr
  $mkgraph_cmd $graph_dir/mkgraph.log \
    utils/mkgraph.sh data/lang_test_bd_tgpr ${working_dir}/tri5a $graph_dir || exit 1;
  steps/decode.sh --nj 10 --cmd "$decode_cmd" $decode_param --scoring-opts "$scoring_opts" \
      $graph_dir $datadir/test_dev93 ${working_dir}/tri5a/decode_bd_tgpr_dev93 || exit 1;
  steps/decode.sh --nj 8 --cmd "$decode_cmd" $decode_param --scoring-opts "$scoring_opts" \
      $graph_dir $datadir/test_eval92 ${working_dir}/tri5a/decode_bd_tgpr_eval92 || exit 1;
  touch $working_dir/lda.mllt.done
fi

if [ ! -f $working_dir/mmi.done ]; then
  echo "Generating num alignment and den lats"
  steps/align_si.sh --nj 24 --cmd "$train_cmd" \
    $datadir/train_si284 data/lang ${working_dir}/tri5a ${working_dir}/tri5a_ali || exit 1;

  steps/make_denlats.sh --nj 24 --cmd "$decode_cmd" $denlats_param \
    $datadir/train_si284 data/lang ${working_dir}/tri5a ${working_dir}/tri5a_denlats || exit 1;

  echo "Training bMMI"
  # 4 iterations of MMI
  num_mmi_iters=4
  steps/train_mmi.sh --cmd "$train_cmd" --boost 0.1 --num-iters $num_mmi_iters \
    $datadir/train_si284 data/lang $working_dir/tri5a_{ali,denlats} $working_dir/tri5a_mmi_b0.1 || exit 1;

  for iter in 1 2 3 4; do
    echo "Decoding bMMI iteration $iter"
    graph_dir=$working_dir/tri5a/graph_bd_tgpr
    steps/decode.sh --nj 10 --cmd "$decode_cmd" $decode_param --scoring-opts "$scoring_opts" --iter $iter \
      $graph_dir $datadir/test_dev93 ${working_dir}/tri5a_mmi_b0.1/decode_bd_tgpr_dev93_it$iter || exit 1;
    steps/decode.sh --nj 8 --cmd "$decode_cmd" $decode_param --scoring-opts "$scoring_opts" --iter $iter \
      $graph_dir $datadir/test_eval92 ${working_dir}/tri5a_mmi_b0.1/decode_bd_tgpr_eval92_it$iter || exit 1;
  done
  touch $working_dir/mmi.done
fi

echo "Finish !! You can do things fancier such as SGMM and MMI-SGMM. "
