# Copyright 2013    Yajie Miao    Carnegie Mellon University

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
# WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
# MERCHANTABLITY OR NON-INFRINGEMENT.
# See the Apache 2 License for the specific language governing permissions and
# limitations under the License.

import cPickle
import gzip
import os
import sys
import time

import numpy

import theano
import theano.tensor as T
from theano.tensor.shared_randomstreams import RandomStreams

from layers.logistic_sgd import LogisticRegression
from layers.mlp import HiddenLayer, DropoutHiddenLayer, _dropout_from_layer

class DNN_SAT(object):

    def __init__(self, numpy_rng, theano_rng=None, n_ins=784,
                 hidden_layers_sizes=[500, 500], n_outs=10,
                 activation = T.nnet.sigmoid,
                 do_maxout = False, pool_size = 1, 
                 do_pnorm = False, pnorm_order = 1,
                 max_col_norm = None, l1_reg = None, l2_reg = None,
                 ivec_layers_sizes=[500, 500], ivec_dim = 100):

        self.sigmoid_layers = []
        self.ivec_layers = []

        self.sigmoid_params = []    # params and delta_params for the DNN parameters; the sigmoid prefix is a bit confusing
        self.sigmoid_delta_params = []
        self.ivec_params = []       # params and delta_params for the iVecNN parameters
        self.ivec_delta_params = []
        self.params = []            # the params to be updated in the current training
        self.delta_params   = []

        self.n_layers = len(hidden_layers_sizes)
        self.ivec_layer_num = len(ivec_layers_sizes)

        self.max_col_norm = max_col_norm
        self.l1_reg = l1_reg
        self.l2_reg = l2_reg

        assert self.n_layers > 0

        if not theano_rng:
            theano_rng = RandomStreams(numpy_rng.randint(2 ** 30))
        # allocate symbolic variables for the data
        self.x = T.matrix('x') 
        self.y = T.ivector('y')
        
        # we assume that i-vectors are appended to speech features in a frame-wise manner
        self.iv = self.x[:,n_ins:n_ins+ivec_dim]
        self.raw = self.x[:,0:n_ins]

        # construct the iVecNN which generates linear feature shifts
        for i in xrange(self.ivec_layer_num):
            if i == 0:
                input_size = ivec_dim
                layer_input = self.iv
            else:
                input_size = ivec_layers_sizes[i - 1]
                layer_input = self.ivec_layers[-1].output

            ivec_layer = HiddenLayer(rng=numpy_rng,
                                        input=layer_input,
                                        n_in=input_size,
                                        n_out=ivec_layers_sizes[i],
                                        activation=T.nnet.sigmoid)
            # add the layer to our list of layers
            self.ivec_layers.append(ivec_layer)
            self.ivec_params.extend(ivec_layer.params)
            self.ivec_delta_params.extend(ivec_layer.delta_params)

        # the final output layer which has the same dimension as the input features
        linear_func = lambda x: x
        ivec_layer = HiddenLayer(rng=numpy_rng,
                                 input=self.ivec_layers[-1].output,
                                 n_in=ivec_layers_sizes[-1],
                                 n_out=n_ins,
                                 activation=linear_func)
        self.ivec_layers.append(ivec_layer)
        self.ivec_params.extend(ivec_layer.params)
        self.ivec_delta_params.extend(ivec_layer.delta_params)

        # construct the DNN (canonical model)
        for i in xrange(self.n_layers):
            if i == 0:
                input_size = n_ins
                layer_input = self.raw + self.ivec_layers[-1].output
            else:
                input_size = hidden_layers_sizes[i - 1]
                layer_input = self.sigmoid_layers[-1].output

            if do_maxout == True:
                sigmoid_layer = HiddenLayer(rng=numpy_rng,
                                        input=layer_input,
                                        n_in=input_size,
                                        n_out=hidden_layers_sizes[i] * pool_size,
                                        activation = (lambda x: 1.0*x),
                                        do_maxout = True, pool_size = pool_size)
            elif do_pnorm == True:
                sigmoid_layer = HiddenLayer(rng=numpy_rng,
                                        input=layer_input,
                                        n_in=input_size,
                                        n_out=hidden_layers_sizes[i] * pool_size,
                                        activation = (lambda x: 1.0*x),
                                        do_pnorm = True, pool_size = pool_size, pnorm_order = pnorm_order)
            else:
                sigmoid_layer = HiddenLayer(rng=numpy_rng,
                                        input=layer_input,
                                        n_in=input_size,
                                        n_out=hidden_layers_sizes[i],
                                        activation=activation)
            # add the layer to our list of layers
            self.sigmoid_layers.append(sigmoid_layer)
            self.sigmoid_params.extend(sigmoid_layer.params)
            self.sigmoid_delta_params.extend(sigmoid_layer.delta_params)
        # We now need to add a logistic layer on top of the MLP
        self.logLayer = LogisticRegression(
                         input=self.sigmoid_layers[-1].output,
                         n_in=hidden_layers_sizes[-1], n_out=n_outs)

        self.sigmoid_layers.append(self.logLayer)
        self.sigmoid_params.extend(self.logLayer.params)
        self.sigmoid_delta_params.extend(self.logLayer.delta_params)
       
        # construct a function that implements one step of finetunining
        # compute the cost for second phase of training,
        # defined as the negative log likelihood
        self.finetune_cost = self.logLayer.negative_log_likelihood(self.y)
        self.errors = self.logLayer.errors(self.y)

    def build_finetune_functions(self, train_shared_xy, valid_shared_xy, batch_size):

        (train_set_x, train_set_y) = train_shared_xy
        (valid_set_x, valid_set_y) = valid_shared_xy

        index = T.lscalar('index')  # index to a [mini]batch
        learning_rate = T.fscalar('learning_rate')
        momentum = T.fscalar('momentum')

        # compute the gradients with respect to the model parameters
        gparams = T.grad(self.finetune_cost, self.params)

        # compute list of fine-tuning updates
        updates = {}
        for dparam, gparam in zip(self.delta_params, gparams):
            updates[dparam] = momentum * dparam - gparam*learning_rate
        for dparam, param in zip(self.delta_params, self.params):
            updates[param] = param + updates[dparam]

        train_fn = theano.function(inputs=[index, theano.Param(learning_rate, default = 0.0001),
              theano.Param(momentum, default = 0.5)],
              outputs=self.errors,
              updates=updates,
              givens={
                self.x: train_set_x[index * batch_size:
                                    (index + 1) * batch_size],
                self.y: train_set_y[index * batch_size:
                                    (index + 1) * batch_size]})

        valid_fn = theano.function(inputs=[index],
              outputs=self.errors,
              givens={
                self.x: valid_set_x[index * batch_size:
                                    (index + 1) * batch_size],
                self.y: valid_set_y[index * batch_size:
                                    (index + 1) * batch_size]})

        return train_fn, valid_fn

