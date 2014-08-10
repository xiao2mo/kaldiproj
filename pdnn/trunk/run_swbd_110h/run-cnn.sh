#!/bin/bash

# Apache 2.0
# This script builds CNN hybrid systems over the filterbank features. It is
# to be run after run.sh. Before running this, you should already build the 
# initial GMM model. This script requires a GPU, and  also the "pdnn" tool-
# kit to train the CNN. The input filterbank  features are  with  mean  and
# variance normalization. We are applying 2D convolution (time x frequency).
# You can easily switch to 1D convolution (only on frequency) by redefining
# the CNN architecture.

# For more informaiton regarding the recipes and results, visit our webiste
# http://www.cs.cmu.edu/~ymiao/kaldipdnn

working_dir=exp_pdnn_110h/cnn
delete_pfile=true # whether to delete pfiles after CNN training

gmmdir=exp/tri4a # tri4a is the SAT model trained with 110 hours 
            # data/train_100k_nodup

# Specify the gpu device to be used
gpu=gpu

# Here are two critical variables. With the following default configuration,
# we input speech frames as 29x29 images into CNN. Convolution over the time
# axis is not intuitive. But in practice, this works well. If you change the
# values, then you have to change the CNN definition accordingly.
fbank_dim=29  # the dimension of fbanks on each frame
splice_opts="--left-context=14 --right-context=14"  # splice of fbank frames over time

cmd=run.pl
. cmd.sh
[ -f path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

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
echo "Generate alignment and prepare fbank features"
echo ---------------------------------------------------------------------
# Alignment on the training and validation data
if [ ! -d ${gmmdir}_ali_100k_nodup ]; then
  echo "Generate alignment on train data"
  steps/align_fmllr.sh --nj 24 --cmd "$train_cmd" \
    data/train_100k_nodup data/lang $gmmdir ${gmmdir}_ali_100k_nodup || exit 1
fi
if [ ! -d ${gmmdir}_ali_dev ]; then
  echo "Generate alignment on valid data"
  steps/align_fmllr.sh --nj 24 --cmd "$train_cmd" \
    data/train_dev data/lang $gmmdir ${gmmdir}_ali_dev || exit 1
fi

# Generate the fbank features. We generate 29-dimensional fbanks on each frame; fbank.conf is overwritten here.
echo "--num-mel-bins=$fbank_dim" > conf/fbank.conf
echo "--sample-frequency=8000" >> conf/fbank.conf
mkdir -p $working_dir/data
if [ ! -d $working_dir/data/train ]; then
  echo "Save fbank features of train data"
  cp -r data/train_100k_nodup $working_dir/data/train
  ( cd $working_dir/data/train; rm -rf {cmvn,feats}.scp split*; )
  steps/make_fbank.sh --cmd "$train_cmd" --nj 24 $working_dir/data/train $working_dir/_log $working_dir/_fbank || exit 1;
  utils/fix_data_dir.sh $working_dir/data/train || exit;
  steps/compute_cmvn_stats.sh $working_dir/data/train $working_dir/_log $working_dir/_fbank || exit 1;
fi
if [ ! -d $working_dir/data/valid ]; then
  echo "Save fbank features of valid data"
  cp -r data/train_dev $working_dir/data/valid
  ( cd $working_dir/data/valid; rm -rf {cmvn,feats}.scp split*; )
  steps/make_fbank.sh --cmd "$train_cmd" --nj 24 $working_dir/data/valid $working_dir/_log $working_dir/_fbank || exit 1;
  utils/fix_data_dir.sh $working_dir/data/valid || exit;
  steps/compute_cmvn_stats.sh $working_dir/data/valid $working_dir/_log $working_dir/_fbank || exit 1;
fi
if [ ! -d $working_dir/data/eval2000 ]; then
  echo "Save fbank features of eval2000"
  cp -r data/eval2000 $working_dir/data/eval2000
  ( cd $working_dir/data/eval2000; rm -rf {cmvn,feats}.scp split*; )
  steps/make_fbank.sh --cmd "$train_cmd" --nj 24 $working_dir/data/eval2000 $working_dir/_log $working_dir/_fbank || exit 1;
  utils/fix_data_dir.sh $working_dir/data/eval2000 || exit;
  steps/compute_cmvn_stats.sh $working_dir/data/eval2000 $working_dir/_log $working_dir/_fbank || exit 1;
fi

echo ---------------------------------------------------------------------
echo "Creating CNN training and validation data (pfiles)"
echo ---------------------------------------------------------------------
# By default, inputs include 29 frames (+/-14) of 29-dimensional log-scale filter-banks,
# so that we take each frame as an image.
if [ ! -f $working_dir/train.pfile.done ]; then
  steps_pdnn/build_nnet_pfile.sh --cmd "$train_cmd" --every-nth-frame 1 --do-split false \
    --norm-vars true --splice-opts "$splice_opts" --input-dim 841 \
    $working_dir/data/train ${gmmdir}_ali_100k_nodup $working_dir || exit 1
  ( cd $working_dir; mv concat.pfile train.pfile; )
  touch $working_dir/train.pfile.done
fi
if [ ! -f $working_dir/valid.pfile.done ]; then
  steps_pdnn/build_nnet_pfile.sh --cmd "$train_cmd" --every-nth-frame 1 --do-split false \
    --norm-vars true --splice-opts "$splice_opts" --input-dim 841 \
    $working_dir/data/valid ${gmmdir}_ali_dev $working_dir || exit 1
  ( cd $working_dir; mv concat.pfile valid.pfile; )
  touch $working_dir/valid.pfile.done
fi

echo ---------------------------------------------------------------------
echo "Train CNN acoustic model"
echo ---------------------------------------------------------------------
feat_dim=$(cat $working_dir/train.pfile |head |grep num_features| awk '{print $2}') || exit 1;

if [ ! -f $working_dir/cnn.fine.done ]; then
  echo "$0: Training CNN"
  $cmd $working_dir/log/cnn.fine.log \
    export PYTHONPATH=$PYTHONPATH:`pwd`/pdnn/ \; \
    export THEANO_FLAGS=mode=FAST_RUN,device=$gpu,floatX=float32 \; \
    $pythonCMD pdnn/run_CNN.py --train-data "$working_dir/train.pfile,partition=2000m,random=true,stream=true" \
                          --valid-data "$working_dir/valid.pfile,partition=600m,random=true,stream=true" \
                          --conv-nnet-spec "1x29x29:64,4x4,p2x2:128,5x5,p3x3,f" \
                          --full-nnet-spec "1024:1024:1024:1024:$num_pdfs" \
                          --lrate "D:0.08:0.5:0.2,0.2:8" --momentum 0.5 \
                          --use-fast true \
                          --wdir $working_dir --conv-output-file $working_dir/conv.nnet \
                          --full-output-file $working_dir/dnn.nnet || exit 1;
  touch $working_dir/cnn.fine.done
  $delete_pfile && rm -rf $working_dir/*.pfile
fi

echo "Dump convolution activations on eval2000"
mkdir -p $working_dir/data_conv
cp -r $working_dir/data/eval2000 $working_dir/data_conv/eval2000
( cd $working_dir/data_conv/eval2000; rm -rf {cmvn,feats}.scp split*; )

if [ ! -f $working_dir/txt.feat.done ]; then
  echo "Txt format of fbank features"
  # generate the txt format of fbank features
  steps_pdnn/generate_txt_fbank.sh --cmd "$train_cmd"  \
    --input_splice_opts "$splice_opts" --norm-vars true \
    $working_dir/data/eval2000 $working_dir/_log $working_dir || exit 1;
  if [ ! -f $working_dir/fbank_txt_eval2000.ark ]; then
    echo "No fbank_txt_eval2000.ark was generated" && exit 1;
  fi
  touch $working_dir/txt.feat.done
fi
if [ ! -f $working_dir/conv.feat.done ]; then
  mkdir -p $working_dir/_conv
  echo "Input txt features to the conv net"
  # Now we switch to GPU. Note that conv-layer-number has to comply with your CNN definition
  $cmd $working_dir/_log/conv.feat.log \
    export PYTHONPATH=$PYTHONPATH:`pwd`/pdnn/ \; \
    export THEANO_FLAGS=mode=FAST_RUN,device=$gpu,floatX=float32 \; \
    $pythonCMD pdnn/run_CnnFeat.py --use-fast true --ark-file $working_dir/fbank_txt_eval2000.ark \
                        --conv-net-file $working_dir/conv.nnet --conv-layer-number 2 \
                        --wdir $working_dir --output-file-prefix $working_dir/_conv/conv_eval2000 || exit 1;
  cp $working_dir/_conv/conv_eval2000.scp $working_dir/data_conv/eval2000/feats.scp

  # It's critical to generate "fake" CMVN states here.
  steps/compute_cmvn_stats.sh --fake \
    $working_dir/data_conv/eval2000 $working_dir/_log $working_dir/_conv || exit 1;  
 
  touch $working_dir/conv.feat.done
fi

echo ---------------------------------------------------------------------
echo "Decoding the final system"
echo ---------------------------------------------------------------------
if [ ! -f  $working_dir/decode.done ]; then
  cp $gmmdir/final.mdl $working_dir || exit 1;  # copy final.mdl for scoring
  graph_dir=$gmmdir/graph_sw1_tg
  # No splicing on conv feats. So we reset the splice_opts
  echo "--left-context=0 --right-context=0" > $working_dir/splice_opts
  # Decode
  steps_pdnn/decode_dnn.sh --nj 24 --scoring-opts "--min-lmwt 7 --max-lmwt 18" --cmd "$decode_cmd" --norm-vars false \
    $graph_dir $working_dir/data_conv/eval2000 ${gmmdir}_ali_100k_nodup $working_dir/decode_eval2000_sw1_tg || exit 1;

  touch $working_dir/decode.done
fi

echo "Finish !!"
